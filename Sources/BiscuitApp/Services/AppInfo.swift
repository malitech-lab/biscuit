import BiscuitKit
import Foundation

/// Static facts about this build, read from the bundle so the packaging script
/// is the single source of truth for the version number.
enum AppInfo {
    /// Reads a string from `Info.plist`, treating blank as absent.
    ///
    /// The reason blank must not count as present is documented on
    /// `BundleConfiguration.nonBlank`, which also carries the tests.
    private static func plistString(_ key: String) -> String? {
        BundleConfiguration.nonBlank(Bundle.main.infoDictionary?[key])
    }

    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "dev.biscuit.Biscuit"

    static let version: String =
        plistString("CFBundleShortVersionString") ?? "0.0.0-dev"

    static let build: String =
        plistString("CFBundleVersion") ?? "0"

    static let name = "Biscuit"

    /// GitHub repository used for update checks. Overridable via Info.plist so a
    /// fork does not need a code change.
    static let repository: String =
        plistString("BiscuitUpdateRepository") ?? "malitech-lab/biscuit"

    /// Base64 Ed25519 public key that release archives must be signed with.
    /// Empty means update verification is impossible and updates are disabled.
    static let updatePublicKey: String =
        plistString("BiscuitUpdatePublicKey") ?? ""

    /// Where the signed image catalogue lives.
    ///
    /// Overridable via Info.plist so a fork can point at its own catalogue
    /// without a code change — and so a development build can be aimed at a
    /// local file server.
    static var catalogueBaseURL: URL {
        BundleConfiguration.catalogueBaseURL(
            configured: plistString("BiscuitCatalogueURL"),
            repository: repository
        ) ?? URL(string: "https://example.invalid/")!
    }

    static var catalogueURL: URL {
        catalogueBaseURL.appendingPathComponent("catalogue.json")
    }

    static var catalogueSignatureURL: URL {
        catalogueBaseURL.appendingPathComponent("catalogue.json.sig")
    }

    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    /// `~/Library/Application Support/Biscuit`, created on demand.
    static func applicationSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }
}

/// Locates executables shipped inside the app bundle.
enum BundledTools {
    /// Path to the privileged helper.
    ///
    /// In a packaged app this is `Contents/MacOS/biscuit-helper`. Under
    /// `swift run` there is no bundle, so the sibling of the running executable
    /// is used instead, which is where SwiftPM puts it.
    static var helperPath: URL {
        let executable = Bundle.main.executableURL
            ?? URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        return executable
            .deletingLastPathComponent()
            .appendingPathComponent("biscuit-helper")
    }

    /// Prefix the helper requires the connecting client's path to start with.
    /// `nil` for a non-bundled development build, which disables that check.
    static var clientBundlePrefix: String? {
        guard AppInfo.isRunningFromAppBundle else { return nil }
        return Bundle.main.bundleURL.path
    }

    /// `wimlib-imagex`, preferring the copy vendored into the bundle so that
    /// behaviour does not vary with the user's Homebrew state.
    static var wimlibPath: String? {
        let candidates = [
            Bundle.main.url(forAuxiliaryExecutable: "wimlib-imagex")?.path,
            Bundle.main.resourceURL?.appendingPathComponent("wimlib-imagex").path,
            "/opt/homebrew/bin/wimlib-imagex",
            "/usr/local/bin/wimlib-imagex"
        ].compactMap { $0 }
        return ProcessRunner.locate(candidates)
    }

    static var isWimlibAvailable: Bool { wimlibPath != nil }
}
