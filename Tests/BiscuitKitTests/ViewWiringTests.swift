import Foundation
import Testing

/// Catches presentation state that nothing consumes.
///
/// `SourceSection` carried a `showCatalogue` flag that a button set to `true`
/// while no `.sheet` was bound to it. The link did nothing, and the entire
/// catalogue browser — several hundred lines, its own tests, a whole feature —
/// was unreachable from the running app. It compiled without a warning,
/// because a `@State Bool` nobody reads is perfectly legal Swift.
///
/// Unit tests cannot catch this: the views are correct in isolation and the
/// coordinator is correct in isolation; only the wiring between them is
/// missing. A UI test would catch it but needs a running app and a signed
/// bundle. Scanning the source is the cheap check that actually fits, so that
/// is what this does.
@Suite("Oberflächen-Verdrahtung")
struct ViewWiringTests {
    /// Modifiers that legitimately consume a `Bool` presentation binding.
    private static let consumers = [
        "sheet", "popover", "alert", "confirmationDialog", "fileImporter",
        "fileExporter", "fileMover", "inspector", "fullScreenCover"
    ]

    private static var viewsDirectory: URL? {
        // Walks up from this file to the package root, so the test does not
        // depend on the working directory the runner happens to use.
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory
                .appendingPathComponent("Sources/BiscuitApp/Views")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Jede gesetzte Präsentationsflagge wird auch ausgewertet")
    func everyPresentationFlagIsConsumed() throws {
        guard let views = Self.viewsDirectory else {
            Issue.record(Comment("Views-Verzeichnis nicht gefunden"))
            return
        }

        let files = try FileManager.default
            .contentsOfDirectory(at: views, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty, "keine View-Dateien gefunden")

        var dead: [String] = []

        for file in files {
            let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
            let name = file.lastPathComponent

            for flag in Self.boolStateFlags(in: text) {
                // Only flags something actually switches on can be dead ends;
                // a flag that is never set is a separate (harmless) matter.
                guard text.contains("\(flag) = true") else { continue }
                let isConsumed = Self.consumers.contains { modifier in
                    text.contains(".\(modifier)(isPresented: $\(flag)")
                        || text.contains(".\(modifier)(\n")
                            && text.contains("isPresented: $\(flag)")
                }
                if !isConsumed {
                    dead.append("\(name): \(flag)")
                }
            }
        }

        #expect(
            dead.isEmpty,
            "Flaggen werden gesetzt, aber von keinem Modifier ausgewertet: \(dead.joined(separator: ", "))"
        )
    }

    /// `@State private var showFoo = false` → `showFoo`.
    private static func boolStateFlags(in text: String) -> [String] {
        var flags: [String] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("@State"), trimmed.contains("= false") else { continue }
            guard let varRange = trimmed.range(of: "var ") else { continue }
            let afterVar = trimmed[varRange.upperBound...]
            let identifier = afterVar.prefix { $0.isLetter || $0.isNumber || $0 == "_" }
            if !identifier.isEmpty { flags.append(String(identifier)) }
        }
        return flags
    }

    /// The specific wiring that was missing, named so a regression is obvious.
    @Test("Der Katalog-Browser ist aus der Quellen-Sektion erreichbar")
    func catalogueBrowserIsReachable() throws {
        guard let views = Self.viewsDirectory else {
            Issue.record(Comment("Views-Verzeichnis nicht gefunden"))
            return
        }
        let text = String(
            decoding: try Data(
                contentsOf: views.appendingPathComponent("SourceSection.swift")
            ),
            as: UTF8.self
        )
        #expect(
            text.contains("CatalogueBrowser("),
            "SourceSection präsentiert den CatalogueBrowser nicht — der Katalog wäre unerreichbar"
        )
    }
}
