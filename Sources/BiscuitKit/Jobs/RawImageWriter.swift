import Foundation

/// Byte-for-byte image writer for the unbuffered `/dev/rdiskN` node.
///
/// Three constraints drive the implementation:
///
/// 1. The raw device accepts only block-size-aligned offsets and lengths, so the
///    final partial block of an image must be zero-padded.
/// 2. Page-aligned buffers let the kernel DMA straight from our memory instead
///    of bouncing through an intermediate copy, which roughly doubles throughput
///    on USB 3 sticks.
/// 3. `F_NOCACHE` on the source keeps a multi-gigabyte ISO from evicting the
///    user's entire page cache.
public struct RawImageWriter: Sendable {
    /// Large enough to keep a USB 3 bulk pipe saturated, small enough that a
///   cancellation is noticed within a few hundred milliseconds.
    public static let bufferSize = 8 * 1024 * 1024

    /// Opening bytes held back until the digest checks out. One mebibyte
    /// comfortably covers the MBR, the GPT header and its partition array.
    public static let headWithholdBytes = 1024 * 1024

    public init() {}

    /// Writes an image to the raw device node.
    ///
    /// Takes an `ImageByteSource` rather than a descriptor so that a plain
    /// `.img` and a `.img.xz` follow exactly the same path — block alignment,
    /// short reads, cancellation and flushing are identical, and only the origin
    /// of the bytes differs.
    ///
    /// The source ultimately comes from a descriptor the app passed over
    /// `SCM_RIGHTS`, never a path opened here: macOS privacy protection is
    /// satisfied by the process that holds the user's consent, and a descriptor
    /// cannot be substituted between validation and writing.
    /// - Parameter expectedDigest: SHA-256 of the *decompressed* image, when
    ///   the catalogue knows it. Verified while writing, and a mismatch leaves
    ///   the disk deliberately unbootable rather than plausibly complete.
    public func write(
        source: any ImageByteSource,
        to device: StorageDevice,
        context: JobContext,
        expectedDigest: String? = nil
    ) async throws -> UInt64 {
        let blockSize = Int(max(device.blockSize, 512))
        let expected = source.totalBytes

        switch CapacityCheck.evaluate(expanded: expected, deviceCapacity: device.sizeBytes) {
        case .fits:
            break
        case .tooSmall(let required, let available):
            throw BiscuitError.deviceTooSmall(required: required, available: available)
        case .uncertain(let estimated, _, let caveat):
            // Proceed, but say so: the write may still hit the end of the disk,
            // and the user should not be surprised by that.
            context.log(
                .warning,
                "expanded size is approximate (\(caveat)): \(ByteCount.format(estimated))"
            )
        case .unknown:
            context.log(.warning, "expanded size unknown; capacity cannot be checked in advance")
        }

        if case .exact(let size) = expected, size == 0 {
            throw BiscuitError(kind: .sourceUnreadable, message: t(.errorSourceEmpty))
        }

        try source.rewind()

        let targetFD = open(device.rawDevicePath, O_WRONLY)
        guard targetFD >= 0 else {
            let code = errno
            throw BiscuitError(
                kind: .writeFailed,
                message: t(.errorDeviceOpenFailed),
                remedy: code == EBUSY
                    ? t(.errorDeviceOpenFailedBusyRemedy)
                    : t(.errorDeviceOpenFailedRemedy),
                diagnostics: "open(\(device.rawDevicePath)): errno \(code): \(String(cString: strerror(code)))"
            )
        }
        defer { close(targetFD) }

        let buffer = try AlignedBuffer(size: Self.bufferSize, alignment: 4096)
        var written: UInt64 = 0
        var throughput = ThroughputEstimator()
        var throttle = ProgressThrottle()
        let started = Date()
        let announcedTotal = expected.value

        // Hashed while writing rather than by re-reading afterwards: the data
        // is already in hand, and a second pass over 9 GB buys nothing.
        var hasher = expectedDigest != nil ? IncrementalHasher(algorithm: .sha256) : nil

        // The first megabyte is held back until the digest is confirmed. The
        // idea is borrowed from Raspberry Pi Imager and it is a good one: a
        // disk missing its partition table is obviously unusable, whereas one
        // written from a corrupted image looks finished and fails later, on
        // other hardware, in a way nobody traces back to here.
        var withheldHead: Data?
        let headLength = expectedDigest != nil ? min(Self.headWithholdBytes, Int(blockSize * 2048)) : 0

        context.report(
            phase: .writing,
            phaseFraction: 0,
            bytesProcessed: 0,
            bytesTotal: announcedTotal,
            detail: t(.detailWritingTo, device.rawDevicePath)
        )

        while true {
            try context.cancellation.check()

            // Driven by end of stream, not by a precomputed length: for bzip2
            // the expanded size is simply not knowable in advance.
            let readCount = try source.read(into: buffer.pointer, count: Self.bufferSize)
            guard readCount > 0 else { break }

            // Running past the end of the device has to be caught here, because
            // the capacity check could not be conclusive for every format.
            guard written + UInt64(readCount) <= device.sizeBytes else {
                throw BiscuitError.deviceTooSmall(
                    required: written + UInt64(readCount),
                    available: device.sizeBytes
                )
            }

            hasher?.update(UnsafeRawBufferPointer(start: buffer.pointer, count: readCount))

            // Divert the opening bytes instead of writing them.
            if headLength > 0, written == 0, withheldHead == nil {
                let keep = min(headLength, readCount)
                withheldHead = Data(bytes: buffer.pointer, count: keep)
                if keep == readCount {
                    written += UInt64(readCount)
                    continue
                }
                // Partially withheld: shift the remainder down so the aligned
                // write below still starts at a block boundary.
                memmove(buffer.pointer, buffer.pointer.advanced(by: keep), readCount - keep)
                guard lseek(targetFD, off_t(keep), SEEK_SET) >= 0 else {
                    throw BiscuitError.posix(errno, operation: "lseek")
                }
            }

            // The raw node rejects a length that is not a block multiple, so the
            // tail of the image is padded with zeros up to the next boundary.
            let padded = Self.roundUp(readCount, to: blockSize)
            if padded > readCount {
                memset(buffer.pointer.advanced(by: readCount), 0, padded - readCount)
            }

            try Self.writeFully(targetFD, from: buffer, count: padded)
            written += UInt64(readCount)

            let rate = throughput.update(bytes: written)
            if throttle.shouldEmit() {
                context.report(
                    phase: .writing,
                    // Indeterminate rather than invented when the total is
                    // unknown: a bar that creeps towards 100 % and then keeps
                    // going is worse than no bar.
                    phaseFraction: announcedTotal.map { Double(written) / Double($0) },
                    bytesProcessed: written,
                    bytesTotal: announcedTotal,
                    bytesPerSecond: rate,
                    secondsRemaining: throughput.secondsRemaining(
                        processed: written,
                        total: announcedTotal
                    ),
                    detail: nil
                )
            }
        }

        context.report(
            phase: .writing,
            phaseFraction: 1,
            bytesProcessed: written,
            bytesTotal: written,
            detail: nil
        )

        // Confirm the digest before the opening bytes go down.
        if let expectedDigest, let hasher {
            let actual = hasher.finalizeHex()
            guard Checksum.matches(actual, expectedDigest) else {
                // The head was never written, so the disk has no partition
                // table and no firmware will try to boot it.
                _ = fsync(targetFD)
                throw BiscuitError(
                    kind: .checksumMismatch,
                    message: t(.errorImageChecksumMismatch),
                    remedy: t(.errorImageChecksumMismatchRemedy),
                    diagnostics: "expected \(expectedDigest), got \(actual)"
                )
            }
            context.log(.info, "image digest verified while writing")
        }

        if let withheldHead {
            try context.cancellation.check()
            guard lseek(targetFD, 0, SEEK_SET) == 0 else {
                throw BiscuitError.posix(errno, operation: "lseek(head)")
            }
            let padded = Self.roundUp(withheldHead.count, to: blockSize)
            memset(buffer.pointer, 0, padded)
            withheldHead.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                memcpy(buffer.pointer, base, withheldHead.count)
            }
            try Self.writeFully(targetFD, from: buffer, count: padded)
            context.log(.info, "wrote withheld first \(withheldHead.count) bytes")
        }

        guard fsync(targetFD) == 0 || errno == ENOTSUP else {
            throw BiscuitError.posix(errno, operation: "fsync")
        }

        let elapsed = Date().timeIntervalSince(started)
        context.log(
            .info,
            "wrote \(ByteCount.format(written)) in \(ByteCount.formatDuration(elapsed)) (\(ByteCount.formatRate(bytesPerSecond: Double(written) / max(elapsed, 0.001))))"
        )
        return written
    }

    // MARK: - Verification

    /// Reads the device back and compares it against the source.
    ///
    /// This is the only reliable way to detect the two failure modes that matter
    /// in practice: counterfeit flash drives that report more capacity than they
    /// have, and sticks whose controller silently drops writes once a wear
    /// threshold is hit. Both produce a stick that looks written and refuses to boot.
    public func verify(
        source: any ImageByteSource,
        against device: StorageDevice,
        bytesWritten: UInt64,
        context: JobContext
    ) async throws {
        let blockSize = Int(max(device.blockSize, 512))

        // For a compressed image this decompresses the whole stream a second
        // time. That is the honest price of checking what actually landed.
        try source.rewind()

        let targetFD = open(device.rawDevicePath, O_RDONLY)
        guard targetFD >= 0 else { throw BiscuitError.posix(errno, operation: "open device") }
        defer { close(targetFD) }

        let sourceBuffer = try AlignedBuffer(size: Self.bufferSize, alignment: 4096)
        let targetBuffer = try AlignedBuffer(size: Self.bufferSize, alignment: 4096)

        var compared: UInt64 = 0
        var throughput = ThroughputEstimator()
        var throttle = ProgressThrottle()

        context.report(
            phase: .verifying,
            phaseFraction: 0,
            bytesProcessed: 0,
            bytesTotal: bytesWritten,
            detail: t(.detailVerifying)
        )

        while compared < bytesWritten {
            try context.cancellation.check()

            let remaining = bytesWritten - compared
            let wanted = Int(min(UInt64(Self.bufferSize), remaining))
            let readCount = try source.read(into: sourceBuffer.pointer, count: wanted)
            guard readCount > 0 else { break }

            // Reads from the raw node are block-granular too.
            let aligned = Self.roundUp(readCount, to: blockSize)
            let deviceRead = try Self.readFully(targetFD, into: targetBuffer, count: aligned)
            guard deviceRead >= readCount else {
                throw BiscuitError(
                    kind: .verificationFailed,
                    message: t(.errorDeviceShorterThanImage),
                    remedy: t(.errorDeviceShorterThanImageRemedy),
                    diagnostics: "bei Offset \(compared): \(deviceRead) statt \(readCount) Bytes gelesen"
                )
            }

            if memcmp(sourceBuffer.pointer, targetBuffer.pointer, readCount) != 0 {
                let offset = compared + UInt64(
                    Self.firstDifference(
                        sourceBuffer.pointer,
                        targetBuffer.pointer,
                        count: readCount
                    )
                )
                throw BiscuitError.verificationFailed(atOffset: offset)
            }

            compared += UInt64(readCount)
            let rate = throughput.update(bytes: compared)
            if throttle.shouldEmit(force: compared >= bytesWritten) {
                context.report(
                    phase: .verifying,
                    phaseFraction: Double(compared) / Double(bytesWritten),
                    bytesProcessed: compared,
                    bytesTotal: bytesWritten,
                    bytesPerSecond: rate,
                    secondsRemaining: throughput.secondsRemaining(
                        processed: compared,
                        total: bytesWritten
                    ),
                    detail: nil
                )
            }
        }

        context.log(.info, "verification passed: \(ByteCount.format(compared)) identical")
    }

    // MARK: - POSIX plumbing

    private static func readFully(
        _ fd: Int32,
        into buffer: AlignedBuffer,
        count: Int
    ) throws -> Int {
        var total = 0
        while total < count {
            let result = Darwin.read(fd, buffer.pointer.advanced(by: total), count - total)
            if result > 0 { total += result; continue }
            if result == 0 { break }
            if errno == EINTR { continue }
            throw BiscuitError.posix(errno, operation: "read")
        }
        return total
    }

    private static func writeFully(
        _ fd: Int32,
        from buffer: AlignedBuffer,
        count: Int
    ) throws {
        var total = 0
        while total < count {
            let result = Darwin.write(fd, buffer.pointer.advanced(by: total), count - total)
            if result > 0 { total += result; continue }
            if errno == EINTR { continue }
            let code = errno
            if code == ENOSPC {
                throw BiscuitError(
                    kind: .deviceTooSmall,
                    message: t(.errorNoSpaceLeft),
                    remedy: t(.errorNoSpaceLeftRemedy)
                )
            }
            throw BiscuitError.writeFailed(
                "write bei Offset \(total): errno \(code): \(String(cString: strerror(code)))"
            )
        }
    }

    private static func roundUp(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 0 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }

    private static func firstDifference(
        _ lhs: UnsafeMutableRawPointer,
        _ rhs: UnsafeMutableRawPointer,
        count: Int
    ) -> Int {
        let a = lhs.assumingMemoryBound(to: UInt8.self)
        let b = rhs.assumingMemoryBound(to: UInt8.self)
        for index in 0..<count where a[index] != b[index] { return index }
        return 0
    }

    public static func fileSize(of url: URL) throws -> UInt64 {
        var statBuffer = stat()
        guard stat(url.path, &statBuffer) == 0 else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorFileSizeUnavailable),
                diagnostics: "stat(\(url.path)): errno \(errno)"
            )
        }
        return UInt64(statBuffer.st_size)
    }
}

/// Page-aligned heap buffer. Raw device I/O on Darwin performs markedly better
/// when the user buffer is page aligned, and some controllers require it.
public final class AlignedBuffer {
    public let pointer: UnsafeMutableRawPointer
    public let size: Int

    public init(size: Int, alignment: Int) throws {
        var raw: UnsafeMutableRawPointer?
        let status = posix_memalign(&raw, alignment, size)
        guard status == 0, let raw else {
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorAllocationFailed),
                diagnostics: "posix_memalign: \(status)"
            )
        }
        self.pointer = raw
        self.size = size
    }

    deinit {
        free(pointer)
    }
}
