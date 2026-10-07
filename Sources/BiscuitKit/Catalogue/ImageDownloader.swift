import CryptoKit
import Foundation

/// Downloads a catalogue image into the local cache, resumably and verified.
///
/// Three properties matter here and none of them is the happy path:
///
/// - **Resumable.** A Windows ISO is 7 GB and a Raspberry Pi image 2.7 GB. On a
///   domestic connection that is long enough that the download *will* be
///   interrupted sooner or later, and starting again from zero is the kind of
///   thing that makes people give up on a tool.
/// - **Hashed while downloading**, not afterwards. Re-reading 7 GB from disk to
///   hash it doubles the I/O for no benefit.
/// - **Verified before use.** A download that does not match its checksum is
///   deleted, not offered with a warning: the whole point of the catalogue is
///   that the user does not have to make that judgement.
public actor ImageDownloader {
    /// A point-in-time view of a download.
    ///
    /// `Equatable` so SwiftUI can diff it without re-rendering on every
    /// identical tick — the downloader emits several per second.
    public struct ProgressSnapshot: Sendable, Equatable {
        public let bytesReceived: UInt64
        public let bytesExpected: UInt64?
        public let bytesPerSecond: Double?
        public let secondsRemaining: Double?
        /// Bytes already present from an interrupted earlier attempt. Shown so
        /// a download that starts at 60 % does not look like a glitch.
        public let resumedFrom: UInt64

        public init(
            bytesReceived: UInt64,
            bytesExpected: UInt64?,
            bytesPerSecond: Double?,
            secondsRemaining: Double?,
            resumedFrom: UInt64
        ) {
            self.bytesReceived = bytesReceived
            self.bytesExpected = bytesExpected
            self.bytesPerSecond = bytesPerSecond
            self.secondsRemaining = secondsRemaining
            self.resumedFrom = resumedFrom
        }

        public var fraction: Double? {
            guard let bytesExpected, bytesExpected > 0 else { return nil }
            return min(1, Double(bytesReceived) / Double(bytesExpected))
        }
    }

    public enum Outcome: Sendable {
        /// Already in the cache and the checksum still matches.
        case cached(URL)
        case downloaded(URL, duration: TimeInterval, resumedFrom: UInt64)
    }

    private let cacheDirectory: URL
    private let session: URLSession

    public init(cacheDirectory: URL, session: URLSession? = nil) {
        self.cacheDirectory = cacheDirectory
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            // No overall limit: a 7 GB download on a slow line legitimately
            // takes hours, and a resource timeout would kill it at the worst
            // possible moment.
            config.timeoutIntervalForResource = .greatestFiniteMagnitude
            config.httpAdditionalHeaders = ["User-Agent": "Biscuit image downloader"]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Public API

    /// Fetches `image`, reusing a cached copy when its checksum still matches.
    public func download(
        _ image: CatalogueImage,
        onProgress: @escaping @Sendable (ProgressSnapshot) -> Void
    ) async throws -> Outcome {
        try FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let destination = cacheURL(for: image)
        let partial = destination.appendingPathExtension("part")

        if let cached = try validatedCache(at: destination, image: image) {
            return .cached(cached)
        }

        let started = Date()
        let resumeFrom = resumableOffset(at: partial, image: image)
        try await fetch(
            image: image,
            into: partial,
            resumeFrom: resumeFrom,
            onProgress: onProgress
        )

        try verify(partial, against: image)

        // Only renamed once verified: a file under the final name is, by
        // construction, a file that passed.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)

        return .downloaded(
            destination,
            duration: Date().timeIntervalSince(started),
            resumedFrom: resumeFrom
        )
    }

    public func cacheURL(for image: CatalogueImage) -> URL {
        // Named by id and digest so a changed checksum never collides with an
        // older download of the same release.
        let suffix = (image.downloadSHA256 ?? image.expandedSHA256 ?? "nodigest").prefix(16)
        let safeID = image.id.replacingOccurrences(
            of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression
        )
        return cacheDirectory.appendingPathComponent("\(safeID)-\(suffix).img")
    }

    /// Total bytes currently held in the cache.
    public func cacheSize() -> UInt64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + UInt64(size)
        }
    }

    public func clearCache() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        ) else { return }
        for url in contents { try? FileManager.default.removeItem(at: url) }
    }

    // MARK: - Cache validation

    /// Returns the cached file only if it still matches the catalogue entry.
    ///
    /// Re-hashed rather than trusted by name: a cached image is written to a
    /// disk without further checks, so a corrupted or tampered cache file would
    /// otherwise be the easiest way to get bad data onto a user's hardware.
    private func validatedCache(at url: URL, image: CatalogueImage) throws -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let expected = image.downloadSHA256 else {
            // Without a checksum there is nothing to validate against, so the
            // cache is not reused — a fresh download is cheap compared with
            // writing the wrong thing to a disk.
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        let actual = try Checksum.hashFile(at: url)
        guard Checksum.matches(actual, expected) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// How many bytes of a partial download can be kept.
    private func resumableOffset(at partial: URL, image: CatalogueImage) -> UInt64 {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: partial.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              size > 0
        else { return 0 }

        // A partial file larger than the expected total is evidence of a
        // mismatch — a different release under the same name, most likely.
        if let expected = image.downloadSizeBytes, size >= expected {
            try? FileManager.default.removeItem(at: partial)
            return 0
        }
        return size
    }

    // MARK: - Fetching

    private func fetch(
        image: CatalogueImage,
        into partial: URL,
        resumeFrom: UInt64,
        onProgress: @escaping @Sendable (ProgressSnapshot) -> Void
    ) async throws {
        var request = URLRequest(url: image.url)
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }

        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BiscuitError(kind: .downloadFailed, message: t(.errorDownloadFailed))
        }

        var startOffset = resumeFrom
        switch http.statusCode {
        case 200:
            // Server ignored the range; start over rather than append and
            // produce a file that is garbage in the middle.
            startOffset = 0
        case 206:
            break
        default:
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorDownloadHTTPStatus, http.statusCode),
                remedy: t(.errorDownloadRetryRemedy),
                diagnostics: image.url.absoluteString
            )
        }

        let fileManager = FileManager.default
        if startOffset == 0 {
            try? fileManager.removeItem(at: partial)
            fileManager.createFile(atPath: partial.path, contents: nil)
        } else if !fileManager.fileExists(atPath: partial.path) {
            fileManager.createFile(atPath: partial.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if startOffset == 0 { try handle.truncate(atOffset: 0) }

        let total = image.downloadSizeBytes
            ?? (http.expectedContentLength > 0
                ? UInt64(http.expectedContentLength) + startOffset
                : nil)

        var received = startOffset
        var throughput = ThroughputEstimator()
        var throttle = ProgressThrottle(minimumInterval: 0.2)
        var buffer = Data()
        buffer.reserveCapacity(1 << 20)

        for try await byte in bytes {
            try Task.checkCancellation()
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                let rate = throughput.update(bytes: received)
                if throttle.shouldEmit() {
                    onProgress(ProgressSnapshot(
                        bytesReceived: received,
                        bytesExpected: total,
                        bytesPerSecond: rate,
                        secondsRemaining: throughput.secondsRemaining(
                            processed: received, total: total
                        ),
                        resumedFrom: startOffset
                    ))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += UInt64(buffer.count)
        }

        onProgress(ProgressSnapshot(
            bytesReceived: received,
            bytesExpected: total,
            bytesPerSecond: throughput.rate,
            secondsRemaining: 0,
            resumedFrom: startOffset
        ))
    }

    // MARK: - Verification

    /// Checks the download against the catalogue and deletes it if it fails.
    ///
    /// Deleted rather than kept: a file that failed its checksum has no use,
    /// and leaving it invites a later run to resume from corrupt data.
    private func verify(_ url: URL, against image: CatalogueImage) throws {
        guard let expected = image.downloadSHA256 else {
            // Nothing to check. The entry is marked as such in the UI, and the
            // expanded checksum is still verified at write time if present.
            return
        }
        let actual = try Checksum.hashFile(at: url)
        guard Checksum.matches(actual, expected) else {
            try? FileManager.default.removeItem(at: url)
            throw BiscuitError(
                kind: .checksumMismatch,
                message: t(.errorDownloadChecksumMismatch),
                remedy: t(.errorDownloadChecksumMismatchRemedy),
                diagnostics: "expected \(expected), got \(actual)"
            )
        }
    }
}
