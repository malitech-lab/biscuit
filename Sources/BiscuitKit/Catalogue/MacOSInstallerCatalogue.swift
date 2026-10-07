import Foundation

/// A full macOS installer Apple offers for download.
public struct MacOSInstaller: Sendable, Equatable, Identifiable {
    /// Build is the only field guaranteed unique: two entries can share a
    /// version string across a re-release.
    public var id: String { build }

    /// Marketing name, e.g. "macOS 27 Golden Gate".
    public let title: String
    /// e.g. "27.0.1"
    public let version: String
    /// e.g. "26A434"
    public let build: String
    public let sizeBytes: UInt64
    /// Apple's "Deferred" flag — set for releases held back by a deferral
    /// policy, typically on managed machines.
    public let isDeferred: Bool

    public init(
        title: String,
        version: String,
        build: String,
        sizeBytes: UInt64,
        isDeferred: Bool
    ) {
        self.title = title
        self.version = version
        self.build = build
        self.sizeBytes = sizeBytes
        self.isDeferred = isDeferred
    }

    public var displayName: String { "\(title) \(version)" }

    /// Major version, for grouping.
    public var majorVersion: Int {
        Int(version.split(separator: ".").first.map(String.init) ?? "") ?? 0
    }
}

/// Lists the macOS installers Apple will hand out, via `softwareupdate`.
///
/// This is the officially supported route, and the reason the macOS side needs
/// no catalogue entry of its own: Apple serves the installers, Apple verifies
/// them, and `softwareupdate` refuses anything that fails its own signature
/// check. There is no checksum for Biscuit to pin and no mirror to distrust —
/// which is a better position than the one the Linux and Windows paths are in.
public struct MacOSInstallerCatalogue: Sendable {
    public static let tool = "/usr/sbin/softwareupdate"

    public init() {}

    /// Fetches the list. Needs no privileges.
    public func list(timeout: TimeInterval = 120) async throws -> [MacOSInstaller] {
        let result = try await ProcessRunner.run(
            Self.tool,
            arguments: ["--list-full-installers"],
            timeout: timeout
        )
        guard result.succeeded else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorMacOSListFailed),
                remedy: t(.errorMacOSListFailedRemedy),
                diagnostics: result.combinedOutput
            )
        }
        // Parsed from stdout; verified that `softwareupdate` puts the list
        // there and leaves stderr empty.
        let installers = Self.parse(result.standardOutput)
        guard !installers.isEmpty else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorMacOSNoInstallers),
                remedy: t(.errorMacOSNoInstallersRemedy),
                diagnostics: result.standardOutput.prefix(500).description
            )
        }
        return installers
    }

    /// Parses the tool's output.
    ///
    /// Each entry looks like:
    ///
    ///     * Title: macOS 27 Golden Gate, Version: 27.0.1, Size: 17955378KiB, Build: 26A434, Deferred: NO
    ///
    /// Field-by-field rather than one positional regex, because Apple has added
    /// fields before — `Deferred` is itself a later addition — and a positional
    /// match would silently stop finding anything the next time.
    public static func parse(_ output: String) -> [MacOSInstaller] {
        var installers: [MacOSInstaller] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("*"), trimmed.contains("Title:") else { continue }

            let fields = Self.fields(in: String(trimmed.dropFirst()))
            guard let title = fields["Title"],
                  let version = fields["Version"],
                  let build = fields["Build"]
            else { continue }

            installers.append(
                MacOSInstaller(
                    title: title,
                    version: version,
                    build: build,
                    sizeBytes: fields["Size"].flatMap(Self.parseSize) ?? 0,
                    // Absent means not deferred; only an explicit YES counts.
                    isDeferred: (fields["Deferred"] ?? "NO").uppercased() == "YES"
                )
            )
        }

        // Newest first. Compared component-wise: "27.0.1" must sort above
        // "27.0", and "26.10" above "26.9" — which a string comparison gets
        // wrong.
        return installers.sorted { lhs, rhs in
            let ordering = Self.compareVersions(lhs.version, rhs.version)
            if ordering != .orderedSame { return ordering == .orderedDescending }
            return lhs.build > rhs.build
        }
    }

    /// Splits `Key: value, Key: value` while tolerating commas inside a value.
    ///
    /// The title legitimately contains spaces and could contain a comma, so the
    /// split is driven by the known keys rather than by the separator.
    private static func fields(in line: String) -> [String: String] {
        let keys = ["Title", "Version", "Size", "Build", "Deferred"]
        var positions: [(key: String, range: Range<String.Index>)] = []
        for key in keys {
            if let range = line.range(of: "\(key): ") {
                positions.append((key, range))
            }
        }
        positions.sort { $0.range.lowerBound < $1.range.lowerBound }

        var result: [String: String] = [:]
        for (index, entry) in positions.enumerated() {
            let valueStart = entry.range.upperBound
            let valueEnd = index + 1 < positions.count
                ? positions[index + 1].range.lowerBound
                : line.endIndex
            var value = String(line[valueStart..<valueEnd])
                .trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(",") { value.removeLast() }
            result[entry.key] = value.trimmingCharacters(in: .whitespaces)
        }
        return result
    }

    /// `17955378KiB` → bytes.
    static func parseSize(_ raw: String) -> UInt64? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let digits = text.prefix { $0.isNumber }
        guard let value = UInt64(digits) else { return nil }
        let unit = text.dropFirst(digits.count).trimmingCharacters(in: .whitespaces).uppercased()
        switch unit {
        case "KIB", "K": return value * 1024
        case "MIB", "M": return value * 1024 * 1024
        case "GIB", "G": return value * 1024 * 1024 * 1024
        case "B", "": return value
        default: return value * 1024   // Apple has only ever emitted KiB.
        }
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}

// MARK: - Fetching

public extension MacOSInstallerCatalogue {
    /// Where `softwareupdate` puts a fetched installer.
    static func expectedInstallerLocation(for installer: MacOSInstaller) -> URL {
        // The tool names the bundle after the marketing title, so
        // "macOS 27 Golden Gate" becomes "Install macOS 27 Golden Gate.app".
        URL(fileURLWithPath: "/Applications")
            .appendingPathComponent("Install \(installer.title).app")
    }

    /// Downloads an installer into `/Applications`.
    ///
    /// Delegated to `softwareupdate` rather than fetched directly: Apple does
    /// not publish stable installer URLs, and the tool verifies its own
    /// download. It writes to `/Applications`, which is why the resulting
    /// bundle is somewhere the privileged helper is allowed to read — unlike
    /// `~/Downloads`.
    ///
    /// - Parameter onProgress: receives 0…1 where the tool reports a percentage.
    func fetch(
        _ installer: MacOSInstaller,
        onProgress: @escaping @Sendable (Double?, String) -> Void
    ) async throws -> URL {
        let reporter = PercentageTracker()

        let result = try await ProcessRunner.runStreaming(
            Self.tool,
            arguments: [
                "--fetch-full-installer",
                "--full-installer-version", installer.version
            ]
        ) { line in
            onProgress(reporter.consume(line), line)
        }

        guard result.succeeded else {
            throw BiscuitError(
                kind: .downloadFailed,
                message: t(.errorMacOSFetchFailed),
                remedy: Self.remedy(for: result.combinedOutput),
                diagnostics: result.combinedOutput
            )
        }

        let expected = Self.expectedInstallerLocation(for: installer)
        if FileManager.default.fileExists(atPath: expected.path) {
            return expected
        }
        // The tool occasionally names the bundle differently from the title it
        // listed, so a scan is the fallback rather than a hard failure.
        if let found = Self.findInstaller(matching: installer) {
            return found
        }
        throw BiscuitError(
            kind: .sourceUnreadable,
            message: t(.errorMacOSInstallerNotFound),
            remedy: t(.errorMacOSInstallerNotFoundRemedy),
            diagnostics: expected.path
        )
    }

    private static func findInstaller(matching installer: MacOSInstaller) -> URL? {
        let applications = URL(fileURLWithPath: "/Applications")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: applications, includingPropertiesForKeys: nil
        ) else { return nil }

        return entries.first { url in
            guard url.pathExtension == "app",
                  url.lastPathComponent.hasPrefix("Install macOS")
            else { return false }
            let createInstallMedia = url
                .appendingPathComponent("Contents/Resources/createinstallmedia")
            guard FileManager.default.isExecutableFile(atPath: createInstallMedia.path) else {
                return false
            }
            // Confirm it is the version that was asked for, so an older
            // installer left in /Applications is not picked up by mistake.
            let plist = url.appendingPathComponent("Contents/Info.plist")
            guard let bundle = Bundle(url: url),
                  let version = bundle.infoDictionary?["DTPlatformVersion"] as? String
                    ?? bundle.infoDictionary?["CFBundleShortVersionString"] as? String
            else {
                _ = plist
                return false
            }
            return installer.version.hasPrefix(version) || version.hasPrefix(installer.version)
        }
    }

    private static func remedy(for output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("no space") || lower.contains("not enough") {
            return t(.errorMacOSFetchNoSpaceRemedy)
        }
        if lower.contains("not found") || lower.contains("could not find") {
            return t(.errorMacOSFetchUnavailableRemedy)
        }
        return t(.errorDownloadRetryRemedy)
    }
}

/// Extracts a monotonically increasing percentage from tool output.
private final class PercentageTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var highest: Double = -1

    func consume(_ line: String) -> Double? {
        guard let percent = ProgressTextParser.percentage(in: line) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard percent > highest else { return highest >= 0 ? highest / 100 : nil }
        highest = percent
        return percent / 100
    }
}
