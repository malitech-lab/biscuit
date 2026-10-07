import Foundation

/// Localisation lookup for every user-facing string in Biscuit.
///
/// Why hand-rolled rather than `String(localized:)` or a String Catalogue:
/// `.xcstrings` files are compiled by a build step that ships only with full
/// Xcode. This project deliberately builds with the Command Line Tools alone, so
/// the string tables are plain `.lproj/Localizable.strings` resources.
///
/// Where they are found is *not* uniform, contrary to what this comment claimed
/// for a while: see `resolvedResourceBundle`. The packaged app and the
/// privileged helper read them from `Contents/Resources`, tests from the
/// SwiftPM resource bundle.
///
/// Two rules keep the result maintainable:
///
/// 1. **Keys are semantic**, never English text. `error.device.too_small`
///    survives a rewording; `"The disk is too small"` as a key does not.
/// 2. **Diagnostics stay English and unlocalised.** Anything that lands in a log
///    or a bug report — `errno` descriptions, tool output, protocol reasons — is
///    meant to be searchable and comparable across machines, so translating it
///    would make support harder rather than easier.
public enum L10n {
    /// Overrides the language, both for the app's language preference and for
    /// tests that need to assert on a specific translation.
    ///
    /// `nil` means: follow the user's system preference.
    nonisolated(unsafe) private static var forcedLanguage: String?
    private static let lock = NSLock()

    public static func setPreferredLanguage(_ code: String?) {
        lock.lock()
        forcedLanguage = code
        lock.unlock()
        cachedBundle.invalidate()
    }

    public static var preferredLanguage: String? {
        lock.lock(); defer { lock.unlock() }
        return forcedLanguage
    }

    /// The module's own resource bundle.
    ///
    /// Exposed because a test target that declares resources of its own gets a
    /// `Bundle.module` that shadows this one — so a test looking for the string
    /// tables would silently search the wrong bundle and report every key as
    /// missing.
    public static var resourceBundle: Bundle { resolvedResourceBundle }

    /// Where the string tables actually are, decided once.
    ///
    /// `Bundle.module` alone is not enough, for two measured reasons.
    ///
    /// **The helper cannot use it at all.** `biscuit-helper` is a plain
    /// executable inside `Contents/MacOS`, so its `Bundle.main` *is* that
    /// directory. Every candidate the generated accessor checks points there,
    /// while the resource bundle sits in `Contents/Resources`. Any localised
    /// message in the helper would therefore hit `Bundle.module`'s
    /// `fatalError` — as root, part-way through writing a disk.
    ///
    /// **And its layout depends on the build system.** SwiftPM generates a
    /// different accessor per build system; the native one compiles in the
    /// absolute path of the build directory and otherwise looks only in the
    /// root of the `.app`, where a bundle may not go because it breaks the code
    /// signature. A release built that way runs on the build machine and
    /// nowhere else — which is exactly how v0.1.0-rc.1 shipped.
    ///
    /// So the packaged app carries its localisation in
    /// `Contents/Resources/<lang>.lproj`, the ordinary place for a macOS app,
    /// and this resolves to it. `Bundle.module` remains the fallback for tests
    /// and `swift run`.
    private static let resolvedResourceBundle: Bundle = {
        // 1. Packaged app: Bundle.main is the .app, resources in Contents/Resources.
        if Bundle.main.url(forResource: "en", withExtension: "lproj") != nil {
            return Bundle.main
        }

        // 2. Helper or other executable inside an app bundle: Bundle.main is
        //    Contents/MacOS, so Contents/Resources is one level up.
        let siblingResources = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        if FileManager.default.fileExists(
            atPath: siblingResources.appendingPathComponent("en.lproj").path
        ), let bundle = Bundle(url: siblingResources) {
            return bundle
        }

        // 3. Tests and `swift run`: the SwiftPM resource bundle.
        return Bundle.module
    }()

    /// Languages the build actually ships.
    public static var availableLanguages: [String] {
        resourceBundle.localizations
            .filter { $0 != "Base" }
            .sorted()
    }

    // MARK: - Lookup

    /// Resolves `key`, substituting positional arguments.
    ///
    /// Returns the key itself if the lookup fails, which is deliberately ugly:
    /// a missing translation should be obvious in the UI and is caught by
    /// `L10nCompletenessTests` before it can ship.
    public static func t(_ key: StringKey, _ arguments: any CVarArg...) -> String {
        let format = rawString(for: key)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: resolvedLanguage), arguments: arguments)
    }

    /// Looks up a key without argument substitution.
    public static func rawString(for key: StringKey) -> String {
        let table = cachedBundle.value
        let value = table.localizedString(
            forKey: key.rawValue,
            value: Self.missingMarker,
            table: "Localizable"
        )
        if value == Self.missingMarker {
            // Fall back to the base language before giving up, so a partially
            // translated language still shows real text.
            if let base = resourceBundle.path(forResource: "en", ofType: "lproj"),
               let baseBundle = Bundle(path: base) {
                let fallback = baseBundle.localizedString(
                    forKey: key.rawValue,
                    value: Self.missingMarker,
                    table: "Localizable"
                )
                if fallback != Self.missingMarker { return fallback }
            }
            return key.rawValue
        }
        return value
    }

    private static let missingMarker = "\u{0}BISCUIT_MISSING\u{0}"

    /// Language actually in effect, after resolving the override and the system
    /// preference against what the build ships.
    public static var resolvedLanguage: String {
        if let forced = preferredLanguage, availableLanguages.contains(forced) {
            return forced
        }
        let preferred = Bundle.preferredLocalizations(from: availableLanguages)
        return preferred.first ?? "en"
    }

    /// Bundle for `resolvedLanguage`, cached because every error message and
    /// every view body hits it.
    private static let cachedBundle = LanguageBundleCache()

    private final class LanguageBundleCache: @unchecked Sendable {
        private let lock = NSLock()
        private var cached: (language: String, bundle: Bundle)?

        var value: Bundle {
            let language = L10n.resolvedLanguage
            lock.lock()
            if let cached, cached.language == language {
                lock.unlock()
                return cached.bundle
            }
            lock.unlock()

            let resolved: Bundle
            if let path = resourceBundle.path(forResource: language, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                resolved = bundle
            } else {
                resolved = resourceBundle
            }

            lock.lock()
            cached = (language, resolved)
            lock.unlock()
            return resolved
        }

        func invalidate() {
            lock.lock()
            cached = nil
            lock.unlock()
        }
    }
}

/// Convenience so view code reads as `.t(.action_write)` rather than spelling
/// out `L10n.t(...)` everywhere.
public func t(_ key: StringKey, _ arguments: any CVarArg...) -> String {
    let format = L10n.rawString(for: key)
    guard !arguments.isEmpty else { return format }
    return String(
        format: format,
        locale: Locale(identifier: L10n.resolvedLanguage),
        arguments: arguments
    )
}
