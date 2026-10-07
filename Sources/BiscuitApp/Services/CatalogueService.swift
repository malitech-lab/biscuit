import BiscuitKit
import Foundation
import Observation

/// Drives catalogue browsing and image downloads for the UI.
///
/// Keeps the loader and the downloader behind one observable object so views
/// never have to reason about which of the two is busy, and so the one piece of
/// state that genuinely matters — "is there a verified local file I can write?"
/// — has a single owner.
@MainActor
@Observable
final class CatalogueService {
    enum CatalogueState: Equatable {
        case idle
        case loading
        case ready(ImageCatalogue, origin: Origin)
        case failed(BiscuitError)

        /// Mirrors `CatalogueLoader.Origin` without leaking the actor's type
        /// into view code.
        enum Origin: Equatable {
            case network(Date)
            case cache(Date, stale: Bool)
        }

        var catalogue: ImageCatalogue? {
            if case .ready(let catalogue, _) = self { return catalogue }
            return nil
        }
    }

    enum DownloadState: Equatable {
        case idle
        case downloading(CatalogueImage, ImageDownloader.ProgressSnapshot)
        case verifying(CatalogueImage)
        case finished(CatalogueImage, URL)
        case failed(CatalogueImage, BiscuitError)

        var activeImage: CatalogueImage? {
            switch self {
            case .downloading(let image, _), .verifying(let image),
                 .finished(let image, _), .failed(let image, _):
                return image
            case .idle:
                return nil
            }
        }

        var isBusy: Bool {
            switch self {
            case .downloading, .verifying: return true
            case .idle, .finished, .failed: return false
            }
        }
    }

    private(set) var catalogueState: CatalogueState = .idle
    private(set) var downloadState: DownloadState = .idle
    private(set) var cacheSizeBytes: UInt64 = 0

    /// macOS installers Apple is offering. Listed separately from the signed
    /// catalogue because Apple serves and verifies them itself — there is no
    /// checksum for Biscuit to pin and no mirror to distrust.
    private(set) var macOSInstallers: [MacOSInstaller] = []
    private(set) var macOSState: MacOSState = .idle

    enum MacOSState: Equatable {
        case idle
        case listing
        case ready
        case fetching(MacOSInstaller, fraction: Double?, detail: String)
        case failed(BiscuitError)

        var isBusy: Bool {
            switch self {
            case .listing, .fetching: return true
            case .idle, .ready, .failed: return false
            }
        }
    }

    private let macOSCatalogue = MacOSInstallerCatalogue()
    private var macOSTask: Task<Void, Never>?
    private let loader: CatalogueLoader
    private let downloader: ImageDownloader
    private var downloadTask: Task<Void, Never>?

    init(appSupport: URL) {
        let cacheDirectory = appSupport.appendingPathComponent("ImageCache", isDirectory: true)
        self.downloader = ImageDownloader(cacheDirectory: cacheDirectory)
        self.loader = CatalogueLoader(configuration: .init(
            catalogueURL: AppInfo.catalogueURL,
            signatureURL: AppInfo.catalogueSignatureURL,
            // The catalogue is signed with the same key as app releases, for
            // the same reason: both decide what code or data lands on the
            // user's machine.
            publicKeyBase64: AppInfo.updatePublicKey,
            cacheDirectory: appSupport.appendingPathComponent("Catalogue", isDirectory: true)
        ))
    }

    // MARK: - Catalogue

    func loadCatalogue(forceRefresh: Bool = false) async {
        guard catalogueState != .loading else { return }
        catalogueState = .loading

        switch await loader.load(forceRefresh: forceRefresh) {
        case .success(let result):
            let origin: CatalogueState.Origin
            switch result.origin {
            case .network(let date):
                origin = .network(date)
            case .notModified(let date):
                origin = .network(date)
            case .cache(let date, let reason):
                // "fresh" means the cached copy is simply still within its
                // refresh window — not a fallback worth warning about.
                origin = .cache(date, stale: reason != "fresh")
            }
            catalogueState = .ready(result.catalogue, origin: origin)
        case .failure(let error):
            catalogueState = .failed(error)
        }

        await refreshCacheSize()
    }

    // MARK: - macOS installers

    func loadMacOSInstallers() async {
        guard !macOSState.isBusy else { return }
        macOSState = .listing
        do {
            macOSInstallers = try await macOSCatalogue.list()
            macOSState = .ready
        } catch {
            macOSInstallers = []
            macOSState = .failed(BiscuitError.wrap(error, kind: .downloadFailed))
        }
    }

    /// Downloads a macOS installer and reports where it landed.
    ///
    /// Roughly 17 GB and twenty minutes, so the progress reporting matters more
    /// here than anywhere else in the app.
    func fetchMacOSInstaller(
        _ installer: MacOSInstaller,
        completion: @escaping @MainActor (Result<URL, BiscuitError>) -> Void
    ) {
        macOSTask?.cancel()
        macOSState = .fetching(installer, fraction: nil, detail: "")

        let handler: @Sendable (Double?, String) -> Void = { [weak self] fraction, line in
            Task { @MainActor in
                guard let self, case .fetching = self.macOSState else { return }
                self.macOSState = .fetching(installer, fraction: fraction, detail: line)
            }
        }

        macOSTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.macOSCatalogue.fetch(installer, onProgress: handler)
                guard !Task.isCancelled else { return }
                self.macOSState = .ready
                completion(.success(url))
            } catch {
                let failure = BiscuitError.wrap(error, kind: .downloadFailed)
                self.macOSState = .failed(failure)
                completion(.failure(failure))
            }
        }
    }

    func cancelMacOSFetch() {
        macOSTask?.cancel()
        macOSTask = nil
        macOSState = .ready
    }

    // MARK: - Download

    func download(_ image: CatalogueImage) {
        downloadTask?.cancel()
        downloadState = .downloading(image, .init(
            bytesReceived: 0,
            bytesExpected: image.downloadSizeBytes,
            bytesPerSecond: nil,
            secondsRemaining: nil,
            resumedFrom: 0
        ))

        // The progress handler is built outside the task on purpose. Nesting a
        // second `[weak self]` inside a closure that has already bound `self`
        // strongly captures the outer strong reference instead of the weak one,
        // which both warns and quietly defeats the point of the weak capture.
        let progressHandler: @Sendable (ImageDownloader.ProgressSnapshot) -> Void = {
            [weak self] progress in
            Task { @MainActor in
                guard let self, self.downloadState.isBusy else { return }
                self.downloadState = .downloading(image, progress)
            }
        }

        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let outcome = try await self.downloader.download(image, onProgress: progressHandler)
                guard !Task.isCancelled else { return }
                switch outcome {
                case .cached(let url), .downloaded(let url, _, _):
                    self.downloadState = .finished(image, url)
                }
            } catch is CancellationError {
                self.downloadState = .idle
            } catch {
                self.downloadState = .failed(image, BiscuitError.wrap(error, kind: .downloadFailed))
            }
            await self.refreshCacheSize()
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadState = .idle
    }

    func clearDownloadState() {
        guard !downloadState.isBusy else { return }
        downloadState = .idle
    }

    // MARK: - Cache

    func refreshCacheSize() async {
        cacheSizeBytes = await downloader.cacheSize()
    }

    func clearImageCache() async {
        await downloader.clearCache()
        await refreshCacheSize()
        clearDownloadState()
    }

    func clearCatalogueCache() async {
        await loader.clearCache()
        catalogueState = .idle
    }
}
