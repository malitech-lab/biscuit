import AppKit
import BiscuitKit
import CryptoKit
import Foundation
import Observation

/// Self-updater backed by GitHub Releases.
///
/// Why this rather than Sparkle: the archive is fetched with `URLSession`, and
/// macOS only applies the `com.apple.quarantine` attribute when a *downloading
/// application* sets it. A build that is not notarised therefore installs and
/// launches without any Gatekeeper prompt when it arrives through this path,
/// whereas the same file downloaded in a browser would be blocked.
///
/// That convenience is only safe because authenticity is established
/// independently: every release archive must carry a detached Ed25519 signature
/// made with the project's release key, and the public half is compiled into the
/// bundle. An attacker who controls the network, GitHub, or the release assets
/// still cannot produce an archive this app will install.
@MainActor
@Observable
final class UpdateService {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case downloading(fraction: Double)
        case verifying
        case readyToRelaunch(stagedAt: URL, version: String)
        case failed(BiscuitError)
    }

    struct Release: Equatable, Sendable {
        let version: String
        let tag: String
        let notes: String
        let publishedAt: Date?
        let archiveURL: URL
        let signatureURL: URL
        let sizeBytes: UInt64
    }

    private(set) var status: Status = .idle

    var isChecking: Bool { status == .checking }

    var availableRelease: Release? {
        if case .available(let release) = status { return release }
        return nil
    }

    private let session: URLSession
    private let defaults = UserDefaults.standard
    private static let lastCheckKey = "BFLastUpdateCheck"
    private static let automaticKey = "BFAutomaticUpdateChecks"
    private static let checkInterval: TimeInterval = 24 * 3600

    var automaticChecksEnabled: Bool {
        get { defaults.object(forKey: Self.automaticKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.automaticKey) }
    }

    var lastCheck: Date? {
        defaults.object(forKey: Self.lastCheckKey) as? Date
    }

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 1800
        configuration.httpAdditionalHeaders = [
            "Accept": "application/vnd.github+json",
            "User-Agent": "Biscuit/\(AppInfo.version)",
            "X-GitHub-Api-Version": "2022-11-28"
        ]
        self.session = URLSession(configuration: configuration)
    }

    // MARK: - Checking

    func checkAutomaticallyIfDue() async {
        guard automaticChecksEnabled else { return }
        if let lastCheck, Date().timeIntervalSince(lastCheck) < Self.checkInterval { return }
        await checkForUpdates(userInitiated: false)
    }

    func checkForUpdates(userInitiated: Bool) async {
        guard !AppInfo.updatePublicKey.isEmpty else {
            if userInitiated {
                status = .failed(BiscuitError(
                    kind: .updateFailed,
                    message: t(.errorUpdateDisabled),
                    remedy: t(.errorUpdateDisabledRemedy)
                ))
            }
            return
        }

        status = .checking
        do {
            let release = try await fetchLatestRelease()
            defaults.set(Date(), forKey: Self.lastCheckKey)

            if SemanticVersion.isNewer(release.version, than: AppInfo.version) {
                status = .available(release)
            } else {
                status = .upToDate(checkedAt: Date())
            }
        } catch {
            let typed = BiscuitError.wrap(error, kind: .downloadFailed)
            if userInitiated {
                status = .failed(typed)
            } else {
                status = .idle
            }
        }
    }

    private func fetchLatestRelease() async throws -> Release {
        guard let url = URL(
            string: "https://api.github.com/repos/\(AppInfo.repository)/releases/latest"
        ) else {
            throw BiscuitError(kind: .updateFailed, message: t(.errorUpdateBadRepository))
        }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw BiscuitError(kind: .downloadFailed, message: t(.errorDownloadNoHTTPResponse))
        }
        guard http.statusCode == 200 else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorDownloadHTTPStatus, http.statusCode),
                remedy: http.statusCode == 404
                    ? t(.errorDownloadNoReleaseRemedy, AppInfo.repository)
                    : t(.errorDownloadRetryRemedy),
                diagnostics: String(decoding: data.prefix(500), as: UTF8.self)
            )
        }

        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadURL: URL
                let size: UInt64

                enum CodingKeys: String, CodingKey {
                    case name
                    case browserDownloadURL = "browser_download_url"
                    case size
                }
            }
            let tagName: String
            let body: String?
            let publishedAt: Date?
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]

            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case body
                case publishedAt = "published_at"
                case draft
                case prerelease
                case assets
            }
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)

        guard !payload.draft, !payload.prerelease else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateDraftRelease)
            )
        }

        guard let archive = payload.assets.first(where: {
            $0.name.hasSuffix(".zip") && !$0.name.hasSuffix(".sig")
        }) else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateNoArchive),
                diagnostics: payload.assets.map(\.name).joined(separator: ", ")
            )
        }

        guard let signature = payload.assets.first(where: {
            $0.name == archive.name + ".sig"
        }) else {
            throw BiscuitError(
                kind: .signatureInvalid,
                message: t(.errorSignatureMissing),
                remedy: t(.errorSignatureMissingRemedy),
                diagnostics: "expected \(archive.name).sig"
            )
        }

        return Release(
            version: SemanticVersion.normalise(payload.tagName),
            tag: payload.tagName,
            notes: payload.body ?? "",
            publishedAt: payload.publishedAt,
            archiveURL: archive.browserDownloadURL,
            signatureURL: signature.browserDownloadURL,
            sizeBytes: archive.size
        )
    }

    // MARK: - Installing

    func downloadAndStage(_ release: Release) async {
        status = .downloading(fraction: 0)
        do {
            let scratch = try Self.makeScratchDirectory()
            let archive = scratch.appendingPathComponent("Biscuit.zip")

            try await download(release.archiveURL, to: archive) { [weak self] fraction in
                Task { @MainActor in self?.status = .downloading(fraction: fraction) }
            }

            status = .verifying
            let signature = try await session.data(from: release.signatureURL).0
            try Self.verifySignature(
                of: archive,
                signature: signature,
                publicKeyBase64: AppInfo.updatePublicKey
            )

            let staged = try await Self.unpack(archive: archive, into: scratch)
            try Self.validateStagedApp(staged, expectedVersion: release.version)

            status = .readyToRelaunch(stagedAt: staged, version: release.version)
        } catch {
            status = .failed(BiscuitError.wrap(error, kind: .updateFailed))
        }
    }

    /// Hands the swap to a detached script, because a process cannot replace its
    /// own bundle while running. The script waits for this PID to exit, moves the
    /// new bundle into place, and relaunches.
    func installAndRelaunch() {
        guard case .readyToRelaunch(let staged, _) = status else { return }
        let destination = Bundle.main.bundleURL

        guard AppInfo.isRunningFromAppBundle else {
            status = .failed(BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateManualOnly),
                remedy: t(.errorUpdateManualOnlyRemedy, staged.deletingLastPathComponent().path)
            ))
            return
        }

        do {
            let script = try Self.writeSwapScript(
                staged: staged,
                destination: destination,
                pid: ProcessInfo.processInfo.processIdentifier
            )
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path]
            try process.run()
            NSApplication.shared.terminate(nil)
        } catch {
            status = .failed(BiscuitError.wrap(error, kind: .updateFailed))
        }
    }

    // MARK: - Download

    private func download(
        _ url: URL,
        to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let (bytes, response) = try await session.bytes(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorDownloadFailed),
                diagnostics: "\(url.lastPathComponent): HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)"
            )
        }
        let expected = response.expectedContentLength

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        var buffer = Data()
        buffer.reserveCapacity(1 << 20)
        var received: Int64 = 0
        var lastReport = Date.distantPast

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 20 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0, Date().timeIntervalSince(lastReport) > 0.1 {
                    lastReport = Date()
                    onProgress(Double(received) / Double(expected))
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        onProgress(1.0)
    }

    // MARK: - Verification

    /// Verifies a detached raw Ed25519 signature over the archive bytes.
    /// Delegates to `BiscuitKit.ReleaseSignature`, which is covered by tests
    /// that round-trip against the exact `openssl` invocation used at release time.
    nonisolated static func verifySignature(
        of archive: URL,
        signature: Data,
        publicKeyBase64: String
    ) throws {
        try ReleaseSignature.verify(
            fileAt: archive,
            signature: signature,
            publicKeyBase64: publicKeyBase64
        )
    }

    /// Rejects a staged bundle that is malformed or not actually newer, so a
    /// rollback attack via a re-tagged old release cannot succeed.
    nonisolated static func validateStagedApp(_ app: URL, expectedVersion: String) throws {
        let fm = FileManager.default
        let executable = app.appendingPathComponent("Contents/MacOS/Biscuit")
        let helper = app.appendingPathComponent("Contents/MacOS/biscuit-helper")

        guard fm.isExecutableFile(atPath: executable.path) else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateNoExecutable),
                diagnostics: executable.path
            )
        }
        guard fm.isExecutableFile(atPath: helper.path) else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateNoHelper),
                diagnostics: helper.path
            )
        }
        guard let bundle = Bundle(url: app),
              let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateInfoPlistUnreadable)
            )
        }
        guard version == expectedVersion else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateVersionMismatch),
                diagnostics: "Release \(expectedVersion), Bundle \(version)"
            )
        }
        guard SemanticVersion.isNewer(version, than: AppInfo.version) else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorUpdateNotNewer),
                diagnostics: "\(version) vs \(AppInfo.version)"
            )
        }
    }

    // MARK: - Filesystem plumbing

    nonisolated static func makeScratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("BiscuitUpdate-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    /// Unpacks with `ditto`, which preserves resource forks, symlinks and the
    /// executable bit — `unzip` does not, and a mangled bundle will not launch.
    nonisolated static func unpack(archive: URL, into scratch: URL) async throws -> URL {
        let destination = scratch.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let result = try await ProcessRunner.run(
            "/usr/bin/ditto",
            arguments: ["-x", "-k", archive.path, destination.path],
            timeout: 600
        )
        guard result.succeeded else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorArchiveExtractFailed),
                diagnostics: result.combinedOutput
            )
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: destination,
            includingPropertiesForKeys: nil
        )
        guard let app = entries.first(where: { $0.pathExtension == "app" }) else {
            throw BiscuitError(
                kind: .updateFailed,
                message: t(.errorArchiveNoApp),
                diagnostics: entries.map(\.lastPathComponent).joined(separator: ", ")
            )
        }
        return app
    }

    /// Emits the swap script. Paths are single-quoted; the script refuses to run
    /// if either path stops being a bundle between staging and execution.
    nonisolated static func writeSwapScript(
        staged: URL,
        destination: URL,
        pid: Int32
    ) throws -> URL {
        let scratch = staged.deletingLastPathComponent()
        let script = scratch.appendingPathComponent("install.sh")

        let quotedStaged = ShellQuoting.quote(staged.path)
        let quotedDestination = ShellQuoting.quote(destination.path)
        let backup = ShellQuoting.quote(destination.path + ".biscuit-old")

        let body = """
        #!/bin/sh
        set -eu

        # Wait for the running instance to exit, but never hang forever.
        for _ in $(seq 1 100); do
          if ! /bin/kill -0 \(pid) 2>/dev/null; then break; fi
          /bin/sleep 0.1
        done

        if [ ! -d \(quotedStaged)/Contents/MacOS ]; then
          echo "staged bundle missing" >&2
          exit 1
        fi

        /bin/rm -rf \(backup)
        if [ -d \(quotedDestination) ]; then
          /bin/mv \(quotedDestination) \(backup)
        fi

        if ! /bin/mv \(quotedStaged) \(quotedDestination); then
          # Roll back rather than leave the user with no app at all.
          if [ -d \(backup) ]; then /bin/mv \(backup) \(quotedDestination); fi
          echo "swap failed" >&2
          exit 1
        fi

        /bin/rm -rf \(backup)
        /usr/bin/xattr -dr com.apple.quarantine \(quotedDestination) 2>/dev/null || true
        /usr/bin/open \(quotedDestination)
        /bin/rm -rf \(ShellQuoting.quote(scratch.path))
        """

        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: script.path
        )
        return script
    }
}
