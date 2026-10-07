import Foundation
import Testing
@testable import BiscuitKit

/// Configuration baked into `Info.plist` by `Scripts/bundle.sh`.
///
/// The bug these exist for: the script writes every `Biscuit*` key
/// unconditionally and leaves unset ones as the empty string. So the key exists,
/// `as? String` yields `""` rather than `nil`, and a `?? fallback` never fires.
/// `catalogueBaseURL` read `""`, built `URL(string: "")` — `nil` — and fell
/// through to `https://example.invalid/`. Every packaged build had a silently
/// dead catalogue, and the branch deriving the real address was unreachable.
@Suite("Bundle-Konfiguration")
struct BundleConfigurationTests {

    // MARK: - Blank versus absent

    @Test("Ein leerer Wert gilt als fehlend, nicht als gesetzt")
    func emptyCountsAsAbsent() {
        // The exact shape bundle.sh produces for an unset key.
        #expect(BundleConfiguration.nonBlank("") == nil)
    }

    @Test("Reiner Weißraum gilt ebenfalls als fehlend")
    func whitespaceCountsAsAbsent() {
        // PlistBuddy and shell substitution both leave stray whitespace behind.
        #expect(BundleConfiguration.nonBlank(" ") == nil)
        #expect(BundleConfiguration.nonBlank("\n") == nil)
        #expect(BundleConfiguration.nonBlank("  \t \n ") == nil)
    }

    @Test("Ein echter Wert kommt getrimmt zurück")
    func realValueIsTrimmed() {
        #expect(BundleConfiguration.nonBlank("malitech-lab/biscuit") == "malitech-lab/biscuit")
        #expect(BundleConfiguration.nonBlank("  malitech-lab/biscuit\n") == "malitech-lab/biscuit")
    }

    @Test("Nicht-Zeichenketten und nil ergeben nil")
    func nonStringsAreNil() {
        #expect(BundleConfiguration.nonBlank(nil) == nil)
        #expect(BundleConfiguration.nonBlank(42) == nil)
        #expect(BundleConfiguration.nonBlank([1, 2]) == nil)
    }

    // MARK: - Catalogue address

    @Test("Die Adresse wird aus owner/repo abgeleitet")
    func addressIsDerivedFromRepository() {
        // Derived rather than configured: GitHub Pages serves a project site at
        // <owner>.github.io/<repo>/, so there is one fewer value that can
        // disagree with reality.
        let url = BundleConfiguration.catalogueBaseURL(
            configured: nil, repository: "malitech-lab/biscuit"
        )
        #expect(url?.absoluteString == "https://malitech-lab.github.io/biscuit/")
    }

    @Test("Die abgeleitete Adresse entspricht der tatsächlich eingerichteten Seite")
    func derivedAddressMatchesLivePages() {
        // Pinned against the address GitHub reported when Pages was enabled for
        // this repository. If the derivation drifts, the catalogue silently
        // stops loading, which is not a failure the app can explain.
        let url = BundleConfiguration.catalogueBaseURL(
            configured: nil, repository: "malitech-lab/biscuit"
        )
        #expect(url?.absoluteString == "https://malitech-lab.github.io/biscuit/")
        #expect(url?.appendingPathComponent("catalogue.json").absoluteString
            == "https://malitech-lab.github.io/biscuit/catalogue.json")
    }

    @Test("Ein leerer Konfigurationswert verdeckt die Ableitung nicht")
    func blankConfiguredDoesNotShadowDerivation() {
        // The regression itself. `nonBlank` turns "" into nil upstream, so the
        // derivation runs — this asserts the two work together.
        let configured = BundleConfiguration.nonBlank("")
        let url = BundleConfiguration.catalogueBaseURL(
            configured: configured, repository: "malitech-lab/biscuit"
        )
        #expect(url?.host == "malitech-lab.github.io")
        #expect(url?.absoluteString != "https://example.invalid/")
    }

    @Test("Ein ausdrücklicher Wert gewinnt")
    func explicitValueWins() {
        // What lets a development build point at a local file server.
        let url = BundleConfiguration.catalogueBaseURL(
            configured: "http://localhost:8000/", repository: "malitech-lab/biscuit"
        )
        #expect(url?.absoluteString == "http://localhost:8000/")
    }

    @Test("Ein unbrauchbares Repository ergibt nil, keine erfundene Adresse")
    func malformedRepositoryYieldsNil() {
        // Returning a half-built address would produce requests to a host that
        // is not ours. nil lets the caller fall back deliberately.
        for repository in ["", "biscuit", "a/b/c", "/biscuit", "malitech-lab/"] {
            #expect(
                BundleConfiguration.catalogueBaseURL(configured: nil, repository: repository) == nil,
                Comment(rawValue: "\(repository.debugDescription) ergab eine Adresse")
            )
        }
    }
}

/// Checks the shipped `Info.plist` template against the reader.
@Suite("Info.plist-Vorlage")
struct InfoPlistTemplateTests {
    private static var templateSource: String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Resources/Info.plist.in")
            if let data = try? Data(contentsOf: candidate) {
                return String(decoding: data, as: UTF8.self)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Die Vorlage enthält die Schlüssel, die die App liest")
    func templateCarriesTheKeys() throws {
        // A key the app reads but the template omits means the fallback is used
        // forever, with nothing to show that the configuration was ignored.
        let template = try #require(Self.templateSource, "Info.plist.in nicht gefunden")
        for key in ["BiscuitUpdateRepository", "BiscuitUpdatePublicKey", "BiscuitCatalogueURL"] {
            #expect(template.contains(key), Comment(rawValue: "\(key) fehlt in der Vorlage"))
        }
    }

    @Test("AppInfo liest über nonBlank, nicht direkt")
    func appInfoUsesNonBlank() throws {
        // The whole point. A direct `as? String ?? fallback` reintroduces the
        // bug, and nothing else would notice.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: String?
        for _ in 0..<5 {
            let candidate = directory
                .appendingPathComponent("Sources/BiscuitApp/Services/AppInfo.swift")
            if let data = try? Data(contentsOf: candidate) {
                source = String(decoding: data, as: UTF8.self)
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        let text = try #require(source, "AppInfo.swift nicht gefunden")
        #expect(text.contains("BundleConfiguration.nonBlank"))
        #expect(
            !text.contains("infoDictionary?[\"Biscuit"),
            "ein Biscuit-Schlüssel wird wieder direkt gelesen"
        )
    }
}
