import CBiscuitArchive
import Foundation

/// Streams the decompressed contents of an image through libarchive.
///
/// Streaming rather than decompressing to a temporary file: a Raspberry Pi OS
/// image is roughly 2.7 GB compressed and 9 GB expanded, so the temp-file route
/// would need 12 GB of free space and write every byte twice — on exactly the
/// machines least likely to have the space.
///
/// Presents the same shape as a plain descriptor read, so `RawImageWriter` does
/// not need to know whether the image was compressed.
public final class DecompressingReader {
    public let format: CompressionFormat
    /// Decompressed size when the container records it.
    public let expandedSize: ExpandedSize

    private var handle: OpaquePointer?
    private var source: OpaquePointer?
    private var finished = false
    private var produced: UInt64 = 0

    /// Running CRC-32 and expected trailer values, for formats libarchive does
    /// not check itself. See `verifyIntegrity`.
    private var runningCRC: UInt32 = 0
    private let gzipTrailer: GZipTrailer?

    private static let readBlockSize = 1 << 20

    /// - Parameter fileDescriptor: stays owned by the caller, is never seeked,
    ///   and is still usable afterwards. Reads go through `pread` with an
    ///   offset this object tracks itself.
    public init(fileDescriptor: Int32, format: CompressionFormat) throws {
        self.format = format
        self.expandedSize = ExpandedSizeReader.read(format: format, fileDescriptor: fileDescriptor)
        self.gzipTrailer = format == .gzip
            ? GZipTrailer.read(from: fileDescriptor)
            : nil

        guard format.isSupported else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorCompressionUnsupported, format.displayName),
                remedy: t(.errorCompressionUnsupportedRemedy)
            )
        }

        guard let archive: OpaquePointer = archive_read_new() else {
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorDecompressionFailed),
                diagnostics: "archive_read_new returned null"
            )
        }
        self.handle = archive

        // Only the filters libarchive has compiled in. `support_filter_all`
        // would also advertise zstd, which it implements by running an external
        // program that the helper's minimal PATH does not contain — an
        // advertised format that fails at write time is worse than a refusal.
        archive_read_support_filter_none(archive)
        archive_read_support_filter_gzip(archive)
        archive_read_support_filter_xz(archive)
        archive_read_support_filter_bzip2(archive)
        archive_read_support_format_raw(archive)
        archive_read_support_format_zip(archive)

        guard let source = biscuit_pread_source_new(fileDescriptor, Self.readBlockSize) else {
            archive_read_free(archive)
            self.handle = nil
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorAllocationFailed)
            )
        }
        self.source = source

        guard biscuit_archive_open_pread(archive, source) == BISCUIT_ARCHIVE_OK else {
            let message = Self.errorText(archive)
            cleanUp()
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorDecompressionFailed),
                remedy: t(.errorDecompressionFailedRemedy),
                diagnostics: "open_pread: \(message)"
            )
        }

        var entry: OpaquePointer?
        guard archive_read_next_header(archive, &entry) == BISCUIT_ARCHIVE_OK else {
            let message = Self.errorText(archive)
            cleanUp()
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorDecompressionFailed),
                remedy: t(.errorDecompressionFailedRemedy),
                diagnostics: "next_header: \(message)"
            )
        }
    }

    deinit {
        cleanUp()
    }

    public func close() {
        cleanUp()
    }

    private func cleanUp() {
        if let handle {
            archive_read_free(handle)
            self.handle = nil
        }
        if let source {
            biscuit_pread_source_free(source)
            self.source = nil
        }
    }

    public var bytesProduced: UInt64 { produced }

    /// Compressed bytes consumed, for progress when the expanded size is unknown.
    public var bytesConsumed: UInt64 {
        guard let handle else { return 0 }
        let value = archive_filter_bytes(handle, -1)
        return value > 0 ? UInt64(value) : 0
    }

    /// Fills `buffer` with up to `count` decompressed bytes. Returns 0 at end of
    /// stream; short reads mid-stream are normal, so callers must loop.
    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        guard !finished, let handle else { return 0 }

        var total = 0
        while total < count {
            let got = archive_read_data(handle, buffer.advanced(by: total), count - total)
            if got > 0 {
                total += got
                continue
            }
            if got == 0 {
                finished = true
                break
            }
            if Int32(got) == BISCUIT_ARCHIVE_RETRY { continue }
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorDecompressionFailed),
                remedy: t(.errorDecompressionTruncatedRemedy),
                diagnostics: "archive_read_data: \(Self.errorText(handle))"
            )
        }

        if total > 0, gzipTrailer != nil {
            runningCRC = biscuit_crc32(runningCRC, buffer, total)
        }
        produced += UInt64(total)

        if finished {
            try verifyIntegrity()
        }
        return total
    }

    /// Checks what libarchive does not.
    ///
    /// Measured on macOS 27 with libarchive 3.7.4: a single flipped byte is
    /// caught for xz ("Corrupted input data"), for bzip2 ("bzip decompression
    /// failed") and for zstd — but **not** for gzip, which reads to the end and
    /// reports no error at all. Writing silently corrupted data and calling it
    /// a success is the one outcome this whole program exists to prevent, so
    /// the gzip trailer is verified here instead.
    private func verifyIntegrity() throws {
        guard let trailer = gzipTrailer else { return }

        guard runningCRC == trailer.crc32 else {
            throw BiscuitError(
                kind: .checksumMismatch,
                message: t(.errorDecompressionCorrupted),
                remedy: t(.errorDecompressionTruncatedRemedy),
                diagnostics: String(
                    format: "gzip crc32 mismatch: computed %08x, expected %08x",
                    runningCRC, trailer.crc32
                )
            )
        }
        // ISIZE is the original size modulo 2³², so only the low word can be
        // compared — which is still enough to catch a truncated stream.
        guard UInt32(truncatingIfNeeded: produced) == trailer.uncompressedSizeLowWord else {
            throw BiscuitError(
                kind: .checksumMismatch,
                message: t(.errorDecompressionCorrupted),
                remedy: t(.errorDecompressionTruncatedRemedy),
                diagnostics: "gzip isize mismatch: produced \(produced)"
            )
        }
    }

    private static func errorText(_ archive: OpaquePointer) -> String {
        if let text = archive_error_string(archive) {
            return String(cString: text) + " (errno \(archive_errno(archive)))"
        }
        return "errno \(archive_errno(archive))"
    }
}

/// The eight-byte gzip trailer: CRC-32 of the uncompressed data, then its size
/// modulo 2³².
struct GZipTrailer: Sendable, Equatable {
    let crc32: UInt32
    let uncompressedSizeLowWord: UInt32

    static func read(from fd: Int32) -> GZipTrailer? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 18 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: 8)
        let read = bytes.withUnsafeMutableBytes { raw -> Int in
            pread(fd, raw.baseAddress, 8, off_t(info.st_size) - 8)
        }
        guard read == 8 else { return nil }
        func word(_ offset: Int) -> UInt32 {
            UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        return GZipTrailer(crc32: word(0), uncompressedSizeLowWord: word(4))
    }
}

// MARK: - Detection

public extension CompressionFormat {
    /// Reads the magic bytes without disturbing the descriptor's offset.
    static func detect(fileDescriptor: Int32) -> CompressionFormat {
        var buffer = [UInt8](repeating: 0, count: 8)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            pread(fileDescriptor, raw.baseAddress, 8, 0)
        }
        guard read > 0 else { return .none }
        return detect(magic: Data(buffer.prefix(read)))
    }

    /// Formats the bundled libarchive can decode without an external program.
    ///
    /// zstd is excluded deliberately: libarchive on macOS is built without it
    /// and shells out to a `zstd` binary, which the privileged helper's minimal
    /// PATH does not contain — and extending that PATH in a root process is the
    /// kind of shortcut this project avoids.
    var isSupported: Bool {
        switch self {
        case .none, .gzip, .xz, .bzip2, .zip: return true
        case .zstd: return false
        }
    }
}
