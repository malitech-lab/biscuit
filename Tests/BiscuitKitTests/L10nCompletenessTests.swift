import Foundation
import Testing
@testable import BiscuitKit

/// Guards the string tables.
///
/// A missing translation is the kind of defect that reaches users easily: it
/// compiles, it passes every other test, and it only shows up as a raw key like
/// `error.device_too_small` in a dialogue — in front of someone whose disk is
/// half-erased. These tests make that a CI failure instead.
@Suite("Lokalisierung", .serialized)
struct L10nCompletenessTests {
    @Test("Beide Sprachen sind im Build enthalten")
    func shippedLanguages() {
        let languages = L10n.availableLanguages
        #expect(languages.contains("en"), "Basissprache fehlt")
        #expect(languages.contains("de"), "Deutsch fehlt")
    }

    @Test("Jeder Schlüssel ist in jeder Sprache übersetzt")
    func everyKeyIsTranslated() throws {
        for language in L10n.availableLanguages {
            let table = try Self.loadTable(language: language)
            var missing: [String] = []

            for key in StringKey.allCases where table[key.rawValue] == nil {
                missing.append(key.rawValue)
            }

            #expect(
                missing.isEmpty,
                "\(language): \(missing.count) Schlüssel fehlen — \(missing.prefix(10).joined(separator: ", "))"
            )
        }
    }

    @Test("Keine Übersetzung ist leer")
    func noEmptyTranslations() throws {
        for language in L10n.availableLanguages {
            let table = try Self.loadTable(language: language)
            let empty = StringKey.allCases.filter { key in
                guard let value = table[key.rawValue] else { return false }
                return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            #expect(empty.isEmpty, "\(language): leere Werte bei \(empty.map(\.rawValue))")
        }
    }

    @Test("Platzhalter stimmen zwischen den Sprachen überein")
    func placeholdersMatchAcrossLanguages() throws {
        // A translation that drops a `%@` produces a message missing its most
        // important detail; one that adds a placeholder crashes `String(format:)`.
        let base = try Self.loadTable(language: "en")

        for language in L10n.availableLanguages where language != "en" {
            let table = try Self.loadTable(language: language)
            for key in StringKey.allCases {
                guard let baseValue = base[key.rawValue],
                      let value = table[key.rawValue] else { continue }
                let expected = Self.placeholders(in: baseValue)
                let actual = Self.placeholders(in: value)
                #expect(
                    expected == actual,
                    "\(language) / \(key.rawValue): Platzhalter \(actual) statt \(expected)"
                )
            }
        }
    }

    @Test("Als parametrisiert markierte Schlüssel haben auch Platzhalter")
    func parameterisedKeysDeclarePlaceholders() throws {
        let base = try Self.loadTable(language: "en")
        for key in StringKey.parameterised {
            let value = try #require(base[key.rawValue], "\(key.rawValue) fehlt")
            #expect(
                !Self.placeholders(in: value).isEmpty,
                "\(key.rawValue) ist als parametrisiert markiert, hat aber keinen Platzhalter"
            )
        }
        // And the converse: anything with a placeholder must be declared, or a
        // caller will forget to pass the argument.
        for key in StringKey.allCases {
            guard let value = base[key.rawValue] else { continue }
            if !Self.placeholders(in: value).isEmpty {
                #expect(
                    StringKey.parameterised.contains(key),
                    "\(key.rawValue) hat Platzhalter, fehlt aber in StringKey.parameterised"
                )
            }
        }
    }

    @Test("Lookup liefert echten Text, nicht den Schlüssel")
    func lookupReturnsText() {
        for language in L10n.availableLanguages {
            L10n.setPreferredLanguage(language)
            defer { L10n.setPreferredLanguage(nil) }

            for key in StringKey.allCases {
                let value = L10n.rawString(for: key)
                #expect(value != key.rawValue, "\(language): \(key.rawValue) nicht aufgelöst")
            }
        }
    }

    @Test("Sprachumschaltung wirkt sofort")
    func switchingLanguageTakesEffect() {
        defer { L10n.setPreferredLanguage(nil) }

        L10n.setPreferredLanguage("en")
        let english = L10n.t(.phaseWriting)
        L10n.setPreferredLanguage("de")
        let german = L10n.t(.phaseWriting)

        #expect(english == "Writing image")
        #expect(german == "Abbild schreiben")
        // The cache must not serve a stale language.
        #expect(english != german)
    }

    @Test("Formatargumente werden eingesetzt")
    func formatArguments() {
        defer { L10n.setPreferredLanguage(nil) }
        L10n.setPreferredLanguage("en")

        #expect(L10n.t(.errorDeviceNotEligible, "disk4") == "disk4 is not a permitted target.")

        // Numbers are formatted for the active locale, so a byte offset reads as
        // "123,456" in English and "123.456" in German. That is intentional —
        // a raw nine-digit run is hard to compare against a hex dump.
        #expect(L10n.t(.errorVerificationFailed, UInt64(123_456)).contains("123,456"))
        L10n.setPreferredLanguage("de")
        #expect(L10n.t(.errorVerificationFailed, UInt64(123_456)).contains("123.456"))
        L10n.setPreferredLanguage("en")
        // Positional arguments must keep their order.
        let remedy = L10n.t(.errorDeviceTooSmallRemedy, "8 GB", "4 GB")
        #expect(remedy.contains("Required: 8 GB"))
        #expect(remedy.contains("Available: 4 GB"))
    }

    @Test("Unbekannte Sprache fällt auf die Basissprache zurück")
    func unknownLanguageFallsBack() {
        defer { L10n.setPreferredLanguage(nil) }
        L10n.setPreferredLanguage("xx-XX")
        // Must still produce real text rather than a key.
        let value = L10n.rawString(for: .phaseDone)
        #expect(value != StringKey.phaseDone.rawValue)
    }

    // MARK: - Helpers

    /// Parses a `.strings` file straight from the resource bundle.
    ///
    /// Read as a property list rather than through `Bundle.localizedString`, so
    /// a missing key is visible as absent instead of silently echoing the key.
    private static func loadTable(language: String) throws -> [String: String] {
        let bundle = L10n.resourceBundle
        let url = try #require(
            bundle.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language),
            "Keine Localizable.strings für \(language)"
        )
        let data = try Data(contentsOf: url)
        let parsed = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        )
        return try #require(parsed as? [String: String], "\(language): unerwartetes Format")
    }

    /// Conversion characters that terminate a format specifier.
    ///
    /// `@` has to be in here explicitly: it is the Foundation object specifier
    /// and, unlike `d` or `s`, it is not a letter. Scanning only for letters
    /// makes `%1$@` run off the end of the string and silently compare garbage —
    /// which is exactly what the first version of this helper did.
    private static let conversionCharacters = Set("diouxXeEfFgGaAcsSpn@")

    /// Extracts format specifiers so two translations can be compared.
    ///
    /// Positional forms are normalised: `%1$@` and `%@` both report as `%@`,
    /// because a translator legitimately switches between them when the word
    /// order changes. What must not differ is the *set* of conversions.
    private static func placeholders(in value: String) -> [String] {
        var found: [String] = []
        var index = value.startIndex

        while index < value.endIndex {
            guard let percent = value[index...].firstIndex(of: "%") else { break }
            var cursor = value.index(after: percent)
            guard cursor < value.endIndex else { break }

            if value[cursor] == "%" {
                // Escaped literal percent, not a placeholder.
                index = value.index(after: cursor)
                continue
            }

            var specifier = ""
            var terminated = false
            while cursor < value.endIndex {
                let character = value[cursor]
                cursor = value.index(after: cursor)
                if conversionCharacters.contains(character) {
                    specifier.append(character)
                    terminated = true
                    break
                }
                specifier.append(character)
            }

            if terminated {
                // Drop the positional prefix (`1$`) and any width/flags so that
                // `%1$@` and `%@` compare equal.
                let conversion = specifier.last.map(String.init) ?? ""
                let lengthModifiers = specifier
                    .dropLast()
                    .filter { "hlLqjzt".contains($0) }
                found.append("%" + lengthModifiers + conversion)
            }
            index = cursor
        }
        return found.sorted()
    }
}

/// Catches a localised string that no code reaches.
///
/// `OutcomeSection` displayed a German string literal baked into Swift while a
/// perfectly good `ui.outcome.windows_boot_hint` sat in both `.strings` files,
/// unused. English users were shown German. Neither the compiler nor
/// `L10nCompletenessTests` could see it: the key existed in both languages, so
/// completeness was satisfied, and a hardcoded literal is valid Swift.
///
/// An unused key is the signature of that mistake. It is also the signature of
/// something harmless — a key left behind after a refactor — so this test
/// cannot simply forbid them. It forbids *unknown* ones: anything deliberately
/// retained goes in the allow-list below, with a reason.
@Suite("Verwendung der Zeichenketten")
struct StringKeyUsageTests {
    /// Keys that exist on purpose without a call site.
    ///
    /// Empty today. Previously held thirteen entries that turned out to be
    /// genuinely dead — seven error keys superseded by the convenience
    /// constructors on `BiscuitError`, which carry their own localised message,
    /// and three answer-file findings the UI deliberately aggregates instead of
    /// listing. All were deleted rather than excused.
    static let intentionallyUnused: Set<String> = []

    private static var sourcesDirectory: URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Sources")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Jeder Schlüssel wird irgendwo verwendet")
    func everyKeyIsReferenced() throws {
        guard let sources = Self.sourcesDirectory else {
            Issue.record(Comment("Sources-Verzeichnis nicht gefunden")); return
        }

        // The declaration file is read separately: its `case` lines are the
        // declarations themselves and must not count as usage, but the key
        // lists further down the same file must.
        let declarationURL = sources
            .appendingPathComponent("BiscuitKit/Localization/StringKey.swift")
        let declaration = String(
            decoding: try Data(contentsOf: declarationURL), as: UTF8.self
        )

        var corpus = ""
        if let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) {
            for case let url as URL in walker where url.pathExtension == "swift" {
                guard url.lastPathComponent != "StringKey.swift" else { continue }
                corpus += String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            }
        }
        // Strip the `case x = "y"` declarations, keep everything else.
        corpus += declaration.replacingOccurrences(
            of: #"(?m)^\s*case \w+ = "[^"]*""#, with: "", options: .regularExpression
        )
        #expect(!corpus.isEmpty, "keine Quellen gelesen")

        var unused: [String] = []
        for key in StringKey.allCases {
            let name = String(describing: key)
            guard !Self.intentionallyUnused.contains(name) else { continue }
            if !corpus.contains(".\(name)") { unused.append(name) }
        }

        #expect(
            unused.isEmpty,
            """
            Lokalisierte Schlüssel ohne Verwendung: \(unused.joined(separator: ", ")). \
            Entweder wird stattdessen ein fest eincodierter Text angezeigt, oder \
            der Schlüssel ist tot und gehört gelöscht.
            """
        )
    }

    /// The specific regression, named so it cannot come back quietly.
    @Test("Der Windows-Start-Hinweis kommt aus der Lokalisierung")
    func bootHintIsLocalised() throws {
        guard let sources = Self.sourcesDirectory else {
            Issue.record(Comment("Sources-Verzeichnis nicht gefunden")); return
        }
        let text = String(
            decoding: try Data(
                contentsOf: sources.appendingPathComponent("BiscuitApp/Views/OutcomeSection.swift")
            ),
            as: UTF8.self
        )
        #expect(text.contains("t(.outcomeWindowsBootHint)"))
        // The German wording that used to be inlined here.
        #expect(
            !text.contains("Hinweis zum Start"),
            "fest eincodierter deutscher Text ist zurück"
        )
    }
}

/// Enforces the project's language rule on diagnostics.
///
/// The rule: user-facing text is localised through `t(.key)`; diagnostics —
/// errno values, tool output, protocol reasons, startup failures — stay in
/// English and unlocalised, so that two users filing the same bug produce
/// comparable reports and a maintainer can search for the string.
///
/// The rule was being broken in nine places, in German, including the
/// mismatched-device diagnostic that fires when a USB stick is swapped between
/// confirming and writing — the one a bug report would most likely quote. None
/// of it was visible to any existing test, because every string was valid Swift
/// in the wrong language.
///
/// A hand search found four of the nine; the remaining five sat on string
/// continuation lines and in the helper's startup path, which is why this is a
/// test and not a one-off grep.
@Suite("Sprachregel für Diagnosen")
struct DiagnosticLanguageTests {
    /// Words that mark a string as German prose rather than a symbol or path.
    private static let germanMarkers = [
        "erwartet", "erhalten", "gefunden", "konnte", "liegt", "wurde",
        "keine", "nicht", "ungültig", "fehlt", "bereits", "muss", "darf",
        "kein", "eine", "einen", "einem", "unter", "über", "beim", "unbekannt"
    ]

    private static var sourcesDirectory: URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Sources")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Keine deutschen Zeichenketten im Quelltext")
    func noGermanStringLiterals() throws {
        guard let sources = Self.sourcesDirectory else {
            Issue.record(Comment("Sources-Verzeichnis nicht gefunden")); return
        }

        var offences: [String] = []
        guard let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil
        ) else {
            Issue.record(Comment("Sources nicht lesbar")); return
        }

        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self)
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Comments are German in places by design; only literals matter.
                guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("*") else { continue }

                for literal in Self.stringLiterals(in: String(line)) {
                    // Localisation keys are lowercase dotted identifiers.
                    guard !Self.isLocalisationKey(literal) else { continue }
                    let lower = literal.lowercased()
                    if Self.germanMarkers.contains(where: { lower.contains($0) })
                        || literal.contains(where: { "äöüßÄÖÜ".contains($0) }) {
                        offences.append(
                            "\(url.lastPathComponent):\(number + 1): \(literal.prefix(60))"
                        )
                    }
                }
            }
        }

        #expect(
            offences.isEmpty,
            """
            Deutsche Zeichenketten im Quelltext — Diagnosen bleiben englisch, \
            benutzersichtbarer Text gehört nach Localizable.strings: \
            \(offences.joined(separator: " | "))
            """
        )
    }

    private static func isLocalisationKey(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "." || $0 == "_" }
    }

    /// Extracts double-quoted literals, honouring backslash escapes.
    private static func stringLiterals(in line: String) -> [String] {
        var results: [String] = []
        var current: String?
        var escaped = false
        for character in line {
            if escaped { current?.append(character); escaped = false; continue }
            if character == "\\" { escaped = true; continue }
            if character == "\"" {
                if let value = current { results.append(value); current = nil } else { current = "" }
                continue
            }
            current?.append(character)
        }
        return results.filter { $0.count >= 6 }
    }
}
