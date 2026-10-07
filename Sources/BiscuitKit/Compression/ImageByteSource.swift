import Foundation

/// A rewindable stream of image bytes.
///
/// Exists so `RawImageWriter` does not need to know whether it is writing a
/// plain `.img` or decompressing a `.img.xz` on the fly. Both cases share every
/// hard part — block alignment, short reads, cancellation, verification — and
/// only differ in where the bytes come from.
///
/// `rewind` is part of the contract because verification re-reads the source
/// from the start. For a compressed image that means decompressing twice, which
/// is the honest cost of checking what actually landed on the disk.
public protocol ImageByteSource: AnyObject {
    /// Total decompressed bytes, if the source can say so before being read.
    var totalBytes: ExpandedSize { get }

    /// Human-readable description of the compression, for logs and the UI.
    var formatDescription: String { get }

    /// Fills `buffer` with up to `count` bytes. Returns 0 at end of stream.
    /// Short reads mid-stream are normal; callers must loop.
    func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int

    /// Restarts from the first byte.
    func rewind() throws
}

/// Reads an uncompressed image straight from a descriptor.
///
/// Uses `pread` with an offset it tracks itself, so the descriptor's own offset
/// is never moved — the caller handed it over via `SCM_RIGHTS` and may still
/// need it. (`dup` would not help: on macOS it shares the offset. Measured.)
public final class DescriptorImageSource: ImageByteSource {
    private let fileDescriptor: Int32
    private var offset: UInt64 = 0
    private let size: UInt64

    public init(fileDescriptor: Int32) throws {
        self.fileDescriptor = fileDescriptor
        var info = stat()
        guard fstat(fileDescriptor, &info) == 0 else {
            throw BiscuitError.posix(errno, operation: "fstat")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorSourceNotRegularFile)
            )
        }
        self.size = UInt64(info.st_size)
    }

    public var totalBytes: ExpandedSize { .exact(size) }
    public var formatDescription: String { CompressionFormat.none.displayName }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        var total = 0
        while total < count {
            let got = pread(
                fileDescriptor,
                buffer.advanced(by: total),
                count - total,
                off_t(offset + UInt64(total))
            )
            if got > 0 { total += got; continue }
            if got == 0 { break }
            if errno == EINTR { continue }
            throw BiscuitError.posix(errno, operation: "pread")
        }
        offset += UInt64(total)
        return total
    }

    public func rewind() throws {
        offset = 0
    }
}

/// Decompresses an image on the fly.
public final class DecompressedImageSource: ImageByteSource {
    private let fileDescriptor: Int32
    private let format: CompressionFormat
    private var reader: DecompressingReader

    public init(fileDescriptor: Int32, format: CompressionFormat) throws {
        self.fileDescriptor = fileDescriptor
        self.format = format
        self.reader = try DecompressingReader(fileDescriptor: fileDescriptor, format: format)
    }

    public var totalBytes: ExpandedSize { reader.expandedSize }
    public var formatDescription: String { format.displayName }

    public func read(into buffer: UnsafeMutableRawPointer, count: Int) throws -> Int {
        try reader.read(into: buffer, count: count)
    }

    /// Tears the decoder down and builds a fresh one. There is no cheaper way
    /// to rewind a compressed stream.
    public func rewind() throws {
        reader.close()
        reader = try DecompressingReader(fileDescriptor: fileDescriptor, format: format)
    }

    deinit {
        reader.close()
    }
}

// MARK: - Factory

public enum ImageSourceFactory {
    /// Builds the right source for whatever the descriptor points at.
    ///
    /// The compression is detected from the magic bytes, never the file name: a
    /// `.img.xz` renamed to `.img` is still xz, and writing that raw produces a
    /// disk that fails to boot with no error anywhere.
    public static func make(fileDescriptor: Int32) throws -> any ImageByteSource {
        let format = CompressionFormat.detect(fileDescriptor: fileDescriptor)
        guard format.isCompressed else {
            return try DescriptorImageSource(fileDescriptor: fileDescriptor)
        }
        guard format.isSupported else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorCompressionUnsupported, format.displayName),
                remedy: t(.errorCompressionUnsupportedRemedy)
            )
        }
        return try DecompressedImageSource(fileDescriptor: fileDescriptor, format: format)
    }
}

// MARK: - Capacity

public enum CapacityCheck {
    public enum Result: Sendable, Equatable {
        case fits
        /// Known not to fit.
        case tooSmall(required: UInt64, available: UInt64)
        /// The size is known but not reliable, so this is a judgement call.
        case uncertain(estimated: UInt64, available: UInt64, caveat: String)
        /// Nothing is known about the expanded size.
        case unknown
    }

    /// Decides whether an image fits, without pretending to know more than it does.
    ///
    /// The distinction matters because the cost of being wrong is asymmetric:
    /// refusing a disk that would have worked is an annoyance, while accepting
    /// one that will not is a disk erased for nothing and a write that dies
    /// part-way through. A gzip image reports its size modulo 2³², so a 9 GiB
    /// Raspberry Pi image claims about 737 MiB — plausible enough to pass a
    /// naive check.
    public static func evaluate(
        expanded: ExpandedSize,
        deviceCapacity: UInt64
    ) -> Result {
        switch expanded {
        case .exact(let size):
            return size <= deviceCapacity
                ? .fits
                : .tooSmall(required: size, available: deviceCapacity)

        case .approximate(let size, let caveat):
            // A figure that is already too large is decisive regardless of how
            // it was obtained — being wrong can only make it larger still.
            if size > deviceCapacity {
                return .tooSmall(required: size, available: deviceCapacity)
            }
            return .uncertain(estimated: size, available: deviceCapacity, caveat: caveat)

        case .unknown:
            return .unknown
        }
    }
}
