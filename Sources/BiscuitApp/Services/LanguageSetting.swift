import BiscuitKit
import Foundation
import Observation

/// What the user picked in Settings › General › Language.
public enum LanguagePreference: Hashable, Sendable {
    /// Follow the system's preferred language order.
    case system
    /// Force a specific language the build ships.
    case explicit(String)

    var storedValue: String {
        switch self {
        case .system: return ""
        case .explicit(let code): return code
        }
    }

    init(storedValue: String) {
        // An empty or unknown value means "system", so a build that drops a
        // language cannot leave the app stuck on one it can no longer resolve.
        if storedValue.isEmpty || !L10n.availableLanguages.contains(storedValue) {
            self = .system
        } else {
            self = .explicit(storedValue)
        }
    }

    /// Endonym for the picker — a language is best labelled in itself, so that
    /// someone who cannot read the current UI language can still find theirs.
    static func displayName(for code: String) -> String {
        let locale = Locale(identifier: code)
        let name = locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}

/// Persists the language choice and applies it to `L10n`.
///
/// Kept separate from `AppEnvironment` so the one piece of global state in the
/// localisation layer has a single, obvious owner.
@MainActor
@Observable
public final class LanguageSetting {
    private static let defaultsKey = "BiscuitPreferredLanguage"

    public var selection: LanguagePreference {
        didSet {
            guard selection != oldValue else { return }
            UserDefaults.standard.set(selection.storedValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    public init() {
        let stored = UserDefaults.standard.string(forKey: Self.defaultsKey) ?? ""
        selection = LanguagePreference(storedValue: stored)
        apply()
    }

    private func apply() {
        switch selection {
        case .system:
            L10n.setPreferredLanguage(nil)
        case .explicit(let code):
            L10n.setPreferredLanguage(code)
        }
    }
}
