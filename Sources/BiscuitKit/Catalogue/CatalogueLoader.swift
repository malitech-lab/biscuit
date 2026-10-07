import CryptoKit
import Foundation

/// Fetches, verifies and caches the image catalogue.
///
/// The catalogue decides what the user downloads and which checksum that
/// download is held to, so it is exactly as security-critical as the app
/// updates — and it is protected the same way: an Ed25519 signature made with
/// the project's release key, whose public half is compiled into the build.
///
/// An attacker who controls the network, the CDN or the hosting account still
/// cannot point a user at a modified image, because they cannot produce a
/// catalogue this code will accept.
public actor CatalogueLoader {
    public struct Configuration: Sendable {
        public let catalogueURL: URL
        public let signatureURL: URL
        public let publicKeyBase64: String
        public let cacheDirectory: URL
        /// Refuses anything larger, so a hostile response cannot exhaust memory.
        public let maximumBytes: Int

        public init(
            catalogueURL: URL,
            signatureURL: URL,
            publicKeyBase64: String,
            cacheDirectory: URL,
            maximumBytes: Int = 8 * 1024 * 1024
        ) {
            self.catalogueURL = catalogueURL
            self.signatureURL = signatureURL
            self.publicKeyBase64 = publicKeyBase64
            self.cacheDirectory = cacheDirectory
            self.maximumBytes = maximumBytes
        }
    }

    /// Where a catalogue came from. Surfaced so the UI can say "offline copy
    /// from Tuesday" rather than silently showing stale entries.
    public enum Origin: Sendable, Equatable {
        case network(fetchedAt: Date)
        case notModified(cachedAt: Date)
        case cache(cachedAt: Date, reason: String)
    }

    public struct LoadResult: Sendable {
        public let catalogue: ImageCatalogue
        public let origin: Origin
    }

    private let configuration: Configuration
    private let session: URLSession

    public init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 20
            config.timeoutIntervalForResource = 120
            config.httpAdditionalHeaders = [
                "User-Agent": "Biscuit catalogue client",
                "Accept": "application/json"
            ]
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Loading

    /// Returns a verified catalogue, preferring the network and falling back to
    /// the cache.
    ///
    /// A network failure must not leave the user with nothing: the cached copy
    /// was signature-checked when it was stored, so serving it is safe — it is
    /// only potentially out of date, which the result says plainly.
    public func load(forceRefresh: Bool = false) async -> Result<LoadResult, BiscuitError> {
        if !forceRefresh, let fresh = loadCacheIfFresh() {
            return .success(fresh)
        }

        do {
            return .success(try await fetchAndVerify())
        } catch {
            let failure = BiscuitError.wrap(error, kind: .downloadFailed)
            if let cached = loadCache() {
                return .success(
                    LoadResult(
                        catalogue: cached.catalogue,
                        origin: .cache(
                            cachedAt: cached.cachedAt,
                            reason: failure.diagnostics ?? failure.message
                        )
                    )
                )
            }
            return .failure(failure)
        }
    }

    private func fetchAndVerify() async throws -> LoadResult {
        var request = URLRequest(url: configuration.catalogueURL)
        // Conditional request: the catalogue changes about once a day, and a
        // 304 costs the publisher's CDN nothing.
        if let etag = cachedETag() {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorCatalogueUnreachable)
            )
        }

        if http.statusCode == 304, let cached = loadCache() {
            touchCacheTimestamp()
            return LoadResult(
                catalogue: cached.catalogue,
                origin: .notModified(cachedAt: cached.cachedAt)
            )
        }

        guard http.statusCode == 200 else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorCatalogueUnreachable),
                remedy: t(.errorDownloadRetryRemedy),
                diagnostics: "HTTP \(http.statusCode)"
            )
        }
        guard data.count <= configuration.maximumBytes else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorCatalogueInvalid),
                diagnostics: "catalogue is \(data.count) bytes, limit \(configuration.maximumBytes)"
            )
        }

        let signature = try await fetchSignature()
        try verify(catalogue: data, signature: signature)

        let catalogue = try decode(data)
        try catalogue.validate()

        // Stored only after it has passed every check, so the cache can never
        // hold something the app would refuse from the network.
        store(data: data, signature: signature, etag: http.value(forHTTPHeaderField: "ETag"))

        return LoadResult(catalogue: catalogue, origin: .network(fetchedAt: Date()))
    }

    private func fetchSignature() async throws -> Data {
        let (data, response) = try await session.data(from: configuration.signatureURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorCatalogueSignatureMissing),
                remedy: t(.errorCatalogueSignatureMissingRemedy)
            )
        }
        return data
    }

    private func verify(catalogue: Data, signature: Data) throws {
        guard !configuration.publicKeyBase64.isEmpty else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorCatalogueNoKey),
                remedy: t(.errorCatalogueNoKeyRemedy)
            )
        }
        let key = try ReleaseSignature.parsePublicKey(base64: configuration.publicKeyBase64)
        try ReleaseSignature.verify(payload: catalogue, signature: signature, publicKey: key)
    }

    private func decode(_ data: Data) throws -> ImageCatalogue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(ImageCatalogue.self, from: data)
        } catch {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorCatalogueInvalid),
                diagnostics: String(describing: error)
            )
        }
    }

    // MARK: - Cache

    private var catalogueFile: URL { configuration.cacheDirectory.appendingPathComponent("catalogue.json") }
    private var signatureFile: URL { configuration.cacheDirectory.appendingPathComponent("catalogue.json.sig") }
    private var metadataFile: URL { configuration.cacheDirectory.appendingPathComponent("catalogue.meta.json") }

    private struct CacheMetadata: Codable {
        var etag: String?
        var cachedAt: Date
    }

    private struct CachedCatalogue {
        let catalogue: ImageCatalogue
        let cachedAt: Date
    }

    /// Reads the cache and re-verifies it.
    ///
    /// Verified again on every read rather than trusted because it was verified
    /// once: the cache lives in the user's Application Support directory, which
    /// any process running as that user can rewrite.
    private func loadCache() -> CachedCatalogue? {
        guard let data = try? Data(contentsOf: catalogueFile),
              let signature = try? Data(contentsOf: signatureFile),
              let metadata = try? JSONDecoder().decode(
                  CacheMetadata.self, from: Data(contentsOf: metadataFile)
              )
        else { return nil }

        do {
            try verify(catalogue: data, signature: signature)
            let catalogue = try decode(data)
            try catalogue.validate()
            return CachedCatalogue(catalogue: catalogue, cachedAt: metadata.cachedAt)
        } catch {
            // A cache that no longer verifies is discarded rather than repaired.
            try? FileManager.default.removeItem(at: catalogueFile)
            try? FileManager.default.removeItem(at: signatureFile)
            try? FileManager.default.removeItem(at: metadataFile)
            return nil
        }
    }

    private func loadCacheIfFresh() -> LoadResult? {
        guard let cached = loadCache() else { return nil }
        let maximumAge = TimeInterval(cached.catalogue.refreshIntervalHours) * 3600
        guard Date().timeIntervalSince(cached.cachedAt) < maximumAge else { return nil }
        return LoadResult(
            catalogue: cached.catalogue,
            origin: .cache(cachedAt: cached.cachedAt, reason: "fresh")
        )
    }

    private func cachedETag() -> String? {
        guard let data = try? Data(contentsOf: metadataFile),
              let metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data)
        else { return nil }
        return metadata.etag
    }

    private func store(data: Data, signature: Data, etag: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(
            at: configuration.cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? data.write(to: catalogueFile, options: [.atomic])
        try? signature.write(to: signatureFile, options: [.atomic])
        let metadata = CacheMetadata(etag: etag, cachedAt: Date())
        if let encoded = try? JSONEncoder().encode(metadata) {
            try? encoded.write(to: metadataFile, options: [.atomic])
        }
    }

    private func touchCacheTimestamp() {
        guard let data = try? Data(contentsOf: metadataFile),
              var metadata = try? JSONDecoder().decode(CacheMetadata.self, from: data)
        else { return }
        metadata.cachedAt = Date()
        if let encoded = try? JSONEncoder().encode(metadata) {
            try? encoded.write(to: metadataFile, options: [.atomic])
        }
    }

    /// Drops the cached catalogue. Used by the diagnostics pane.
    public func clearCache() {
        for url in [catalogueFile, signatureFile, metadataFile] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
