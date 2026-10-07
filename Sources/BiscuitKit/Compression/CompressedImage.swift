import CBiscuitArchive
import Foundation

/// Compression wrapper around a disk image.
///
/// Raspberry Pi OS, most Linux ARM images and many installer images ship as
/// `.img.xz` or `.img.gz`. Refusing them — which Biscuit did until now — pushes
/// the user to decompress by hand, which needs twice the disk space and loses
/// the checksum the publisher provided for the compressed file.
public enum CompressionFormat: String, Codable, Sendable, CaseIterable {
    case none
    case gzip
    case xz
    case bzip2
    case zstd
    case zip

    /// Detected from the magic bytes rather than the file extension: a file
    /// renamed from `.img.xz` to `.img` is still xz, and writing that raw
    /// produces an unbootable disk with no error anywhere.
    public static func detect(magic: Data) -> CompressionFormat {
        let bytes = [UInt8](magic.prefix(8))
        func starts(_ prefix: [UInt8]) -> Bool {
            bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
        }
        if starts([0x1F, 0x8B]) { return .gzip }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if starts([0x42, 0x5A, 0x68]) { return .bzip2 }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if starts([0x50, 0x4B, 0x03, 0x04]) { return .zip }
        return .none
    }

    public var isCompressed: Bool { self != .none }

    public var displayName: String {
        switch self {
        case .none: return "—"
        case .gzip: return "gzip"
        case .xz: return "xz"
        case .bzip2: return "bzip2"
        case .zstd: return "zstd"
        case .zip: return "zip"
        }
    }
}

/// How confident we are about the decompressed size.
///
/// This distinction is not pedantry: the figure decides whether a disk is
/// accepted as large enough, and an over-confident guess means discovering
/// mid-write that the image does not fit — after the disk has been erased.
public enum ExpandedSize: Sendable, Equatable {
    /// Read from a structure that records it exactly.
    case exact(UInt64)
    /// Derived from a field that can be wrong, with the reason.
    case approximate(UInt64, caveat: String)
    /// Not determinable without decompressing the whole stream.
    case unknown

    public var value: UInt64? {
        switch self {
        case .exact(let size): return size
        case .approximate(let size, _): return size
        case .unknown: return nil
        }
    }

    public var isTrustworthy: Bool {
        if case .exact = self { return true }
        return false
    }
}

/// Reads the decompressed size out of a compressed file's own metadata.
///
/// Every value here was verified against a 40 MiB reference image: the xz index
/// and the zstd frame header reported it exactly, and gzip's `ISIZE` matched
/// too — but `ISIZE` is stored modulo 2³², so it is only usable below 4 GiB.
/// Raspberry Pi OS expands to roughly 9 GiB, which is exactly the case where a
/// naive reading would be wrong by 4 GiB and still look plausible.
public enum ExpandedSizeReader {
    public static func read(format: CompressionFormat, fileDescriptor: Int32) -> ExpandedSize {
        switch format {
        case .none:
            return fileSize(of: fileDescriptor).map { ExpandedSize.exact($0) } ?? .unknown
        case .xz:
            return readXZIndex(fileDescriptor) ?? .unknown
        case .gzip:
            return readGZipISize(fileDescriptor) ?? .unknown
        case .zstd:
            return readZstdFrameSize(fileDescriptor) ?? .unknown
        case .bzip2, .zip:
            // bzip2 records nothing. zip does, but only in the central
            // directory, which libarchive already walks for us when the format
            // is used; parsing it twice is not worth it here.
            return .unknown
        }
    }

    // MARK: - xz

    /// Sums the uncompressed sizes in the xz stream index.
    ///
    /// Layout, per the xz file format specification:
    /// stream footer is the last 12 bytes — CRC32(4), backward size(4),
    /// stream flags(2), magic "YZ"(2). The backward size field gives the index
    /// length as `(value + 1) * 4`. The index itself is indicator(1),
    /// record count, then one record per block, each holding an unpadded and
    /// an uncompressed size as base-128 varints.
    static func readXZIndex(_ fd: Int32) -> ExpandedSize? {
        guard let total = fileSize(of: fd), total >= 12 else { return nil }

        guard let footer = read(fd, at: total - 12, count: 12), footer.count == 12 else {
            return nil
        }
        guard footer[10] == UInt8(ascii: "Y"), footer[11] == UInt8(ascii: "Z") else { return nil }

        let backward = footer.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
        }
        let indexSize = (UInt64(backward) + 1) * 4
        guard indexSize > 1, indexSize < 16 * 1024 * 1024, total >= 12 + indexSize else {
            return nil
        }

        guard let index = read(fd, at: total - 12 - indexSize, count: Int(indexSize)),
              index.count == Int(indexSize),
              index.first == 0x00
        else { return nil }

        var cursor = 1
        guard let count = varint(index, &cursor), count > 0, count < 1_000_000 else { return nil }

        var sum: UInt64 = 0
        for _ in 0..<count {
            guard varint(index, &cursor) != nil else { return nil }        // unpadded size
            guard let uncompressed = varint(index, &cursor) else { return nil }
            let (next, overflow) = sum.addingReportingOverflow(uncompressed)
            if overflow { return nil }
            sum = next
        }
        return .exact(sum)
    }

    /// Little-endian base-128 integer, as used throughout the xz format.
    private static func varint(_ data: Data, _ cursor: inout Int) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        let base = data.startIndex
        while cursor < data.count {
            let byte = data[base + cursor]
            cursor += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    // MARK: - gzip

    /// Reads `ISIZE` from the gzip trailer.
    ///
    /// Always flagged approximate: the field is the original size modulo 2³², so
    /// a 9 GiB image reports 737 MiB — a figure that is not obviously wrong and
    /// would happily pass a capacity check.
    static func readGZipISize(_ fd: Int32) -> ExpandedSize? {
        guard let total = fileSize(of: fd), total >= 18 else { return nil }
        guard let trailer = read(fd, at: total - 4, count: 4), trailer.count == 4 else {
            return nil
        }
        let isize = trailer.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
        }
        return .approximate(UInt64(isize), caveat: "gzip_isize_modulo")
    }

    // MARK: - zstd

    /// Reads `Frame_Content_Size` from the zstd frame header, when present.
    static func readZstdFrameSize(_ fd: Int32) -> ExpandedSize? {
        guard let head = read(fd, at: 0, count: 14), head.count >= 6 else { return nil }
        let magic = head.withUnsafeBytes { raw in
            UInt32(littleEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard magic == 0xFD2F_B528 else { return nil }

        let descriptor = head[head.startIndex + 4]
        let fcsFlag = descriptor >> 6
        let singleSegment = (descriptor >> 5) & 1
        var offset = 5 + (singleSegment == 1 ? 0 : 1)

        let fieldSize: Int
        switch fcsFlag {
        case 0: fieldSize = singleSegment == 1 ? 1 : 0
        case 1: fieldSize = 2
        case 2: fieldSize = 4
        case 3: fieldSize = 8
        default: fieldSize = 0
        }
        guard fieldSize > 0, head.count >= offset + fieldSize else { return nil }

        var value: UInt64 = 0
        for index in 0..<fieldSize {
            value |= UInt64(head[head.startIndex + offset + index]) << (8 * UInt64(index))
        }
        offset += fieldSize
        // The two-byte form stores the value minus 256.
        if fieldSize == 2 { value += 256 }
        return .exact(value)
    }

    // MARK: - Helpers

    static func fileSize(of fd: Int32) -> UInt64? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return UInt64(info.st_size)
    }

    /// Positional read that leaves the descriptor's offset untouched, so the
    /// caller can go on streaming from wherever it was.
    private static func read(_ fd: Int32, at offset: UInt64, count: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: count)
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            pread(fd, raw.baseAddress, count, off_t(offset))
        }
        guard read > 0 else { return nil }
        return Data(buffer.prefix(read))
    }
}
