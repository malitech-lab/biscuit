import CryptoKit
import Foundation

/// Streaming digest helpers. Everything is chunked so that a 6 GB ISO never
/// lands in memory.
public enum Checksum {
    public static let chunkSize = 4 * 1024 * 1024

    public enum Algorithm: String, Sendable, CaseIterable {
        case sha256
        case sha512
        case sha1
        case md5

        public var displayName: String {
            switch self {
            case .sha256: return t(.checksumSHA256)
            case .sha512: return t(.checksumSHA512)
            case .sha1: return t(.checksumSHA1)
            case .md5: return t(.checksumMD5)
            }
        }

        /// Expected hex string length, used to auto-detect which algorithm a
        /// user-pasted checksum belongs to.
        public var hexLength: Int {
            switch self {
            case .sha256: return 64
            case .sha512: return 128
            case .sha1: return 40
            case .md5: return 32
            }
        }

        public static func detect(fromHex hex: String) -> Algorithm? {
            let normalised = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            return allCases.first { $0.hexLength == normalised.count }
        }
    }

    /// Hashes a file, reporting progress as a fraction of total bytes.
    public static func hashFile(
        at url: URL,
        algorithm: Algorithm = .sha256,
        onProgress: (@Sendable (UInt64, UInt64) -> Void)? = nil
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let total = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? nil
        var hasher = IncrementalHasher(algorithm: algorithm)
        var processed: UInt64 = 0

        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            hasher.update(chunk)
            processed += UInt64(chunk.count)
            onProgress?(processed, total ?? processed)
        }
        return hasher.finalizeHex()
    }

    public static func hash(_ data: Data, algorithm: Algorithm = .sha256) -> String {
        var hasher = IncrementalHasher(algorithm: algorithm)
        hasher.update(data)
        return hasher.finalizeHex()
    }

    /// Constant-time comparison of two hex digests, case- and whitespace-insensitive.
    public static func matches(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.lowercased().filter { !$0.isWhitespace }.utf8)
        let b = Array(rhs.lowercased().filter { !$0.isWhitespace }.utf8)
        guard a.count == b.count, !a.isEmpty else { return false }
        var difference: UInt8 = 0
        for index in a.indices { difference |= a[index] ^ b[index] }
        return difference == 0
    }
}

/// Small type-erasing wrapper so callers can pick an algorithm at runtime
/// without CryptoKit's generic hash types leaking into every signature.
public struct IncrementalHasher: Sendable {
    private enum Backend {
        case sha256(SHA256)
        case sha512(SHA512)
        case sha1(Insecure.SHA1)
        case md5(Insecure.MD5)
    }

    private var backend: Backend

    public init(algorithm: Checksum.Algorithm) {
        switch algorithm {
        case .sha256: backend = .sha256(SHA256())
        case .sha512: backend = .sha512(SHA512())
        case .sha1: backend = .sha1(Insecure.SHA1())
        case .md5: backend = .md5(Insecure.MD5())
        }
    }

    public mutating func update(_ data: Data) {
        switch backend {
        case .sha256(var hasher): hasher.update(data: data); backend = .sha256(hasher)
        case .sha512(var hasher): hasher.update(data: data); backend = .sha512(hasher)
        case .sha1(var hasher): hasher.update(data: data); backend = .sha1(hasher)
        case .md5(var hasher): hasher.update(data: data); backend = .md5(hasher)
        }
    }

    public mutating func update(_ buffer: UnsafeRawBufferPointer) {
        switch backend {
        case .sha256(var hasher): hasher.update(bufferPointer: buffer); backend = .sha256(hasher)
        case .sha512(var hasher): hasher.update(bufferPointer: buffer); backend = .sha512(hasher)
        case .sha1(var hasher): hasher.update(bufferPointer: buffer); backend = .sha1(hasher)
        case .md5(var hasher): hasher.update(bufferPointer: buffer); backend = .md5(hasher)
        }
    }

    public func finalizeHex() -> String {
        switch backend {
        case .sha256(let hasher): return Self.hex(hasher.finalize())
        case .sha512(let hasher): return Self.hex(hasher.finalize())
        case .sha1(let hasher): return Self.hex(hasher.finalize())
        case .md5(let hasher): return Self.hex(hasher.finalize())
        }
    }

    private static func hex(_ digest: some Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
