import Foundation

/// Reads configuration that `Scripts/bundle.sh` bakes into `Info.plist`.
///
/// Lives here rather than beside `AppInfo` so it can be tested: `BiscuitApp` is
/// an executable target and the test target cannot import it.
public enum BundleConfiguration {
    /// Normalises a value read from `Info.plist`, treating blank as absent.
    ///
    /// `??` alone is not enough. `bundle.sh` writes every `Biscuit*` key
    /// unconditionally and leaves the unset ones as the empty string, so the
    /// key *exists* and `as? String` yields `""` rather than `nil`. A
    /// `?? fallback` therefore never fires and the empty value wins.
    ///
    /// Measured consequence before this existed: `catalogueBaseURL` read
    /// `BiscuitCatalogueURL`, found `""`, built `URL(string: "")` — which is
    /// `nil` — and fell through to `https://example.invalid/`. Every packaged
    /// build had a silently dead catalogue, because the branch that derives the
    /// real GitHub Pages address was unreachable.
    public static func nonBlank(_ raw: Any?) -> String? {
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Where the signed catalogue lives, given an `owner/repo` pair.
    ///
    /// GitHub Pages serves a project site at `<owner>.github.io/<repo>/`, so
    /// the address is derived rather than configured — one fewer value that can
    /// disagree with reality. An explicit `BiscuitCatalogueURL` still wins,
    /// which is what lets a development build point at a local file server.
    public static func catalogueBaseURL(
        configured: String?,
        repository: String
    ) -> URL? {
        if let configured, let url = URL(string: configured) {
            return url
        }
        let parts = repository.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return URL(string: "https://\(parts[0]).github.io/\(parts[1])/")
    }
}
