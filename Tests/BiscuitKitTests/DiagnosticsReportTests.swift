import Foundation
import Testing
@testable import BiscuitKit

/// The text a user pastes into a bug report.
///
/// Two faults sat in it undetected, both found by a real user rather than by a
/// test — because the builder lived in the app target, which the test target
/// cannot import.
///
/// The first was misleading. A user selected a Windows ISO, ran `erase_only`
/// three times, and was surprised each time to find an empty stick. The report
/// header printed
///
///     Quelle: Windows11_Client_x64_de-de_26300_9457.iso windows_installer 9,05 GB
///     Methode: erase_only
///
/// which reads as a promise that the image will be written. The confirmation
/// sheet already omitted the source for this strategy; this text did not.
///
/// The second was the language. These labels were German, in a diagnostic
/// destined for an issue tracker, where the project's rule is English. The test
/// meant to catch that scans for a hand-written list of German words — and
/// contained none of `Ziel`, `Quelle`, `Methode`, `FEHLER`. A word list is
/// never complete, so this suite checks the output instead.
@Suite("Diagnosebericht")
struct DiagnosticsReportTests {
    private var context: DiagnosticsReport.Context {
        .init(
            appVersion: "0.1.0-rc.5",
            appBuild: "11",
            osVersion: "Version 27.0.1 (Build 26A434)",
            target: "Flex Line disk4 31,46 GB USB",
            source: "Windows11_Client_x64_de-de_26300_9457.iso windows_installer 9,05 GB",
            strategy: .eraseOnly
        )
    }

    private var entry: DiagnosticsReport.Entry {
        .init(
            timestamp: Date(timeIntervalSince1970: 0),
            level: "info",
            source: "app",
            message: "starting erase_only on disk4"
        )
    }

    // MARK: - The misleading source line

    @Test("Bei „nur löschen“ erscheint keine Quelle")
    func eraseOnlyOmitsSource() {
        let report = DiagnosticsReport.render(context: context, entries: [entry])
        #expect(!report.contains("Windows11_Client"), "Quelle trotz erase_only genannt")
        #expect(!report.lowercased().contains("source:"))
    }

    @Test("Bei „nur löschen“ steht ausdrücklich, dass nichts geschrieben wird")
    func eraseOnlySaysNothingIsWritten() {
        // The sentence that was missing when a user ran this three times.
        let report = DiagnosticsReport.render(context: context, entries: [entry])
        #expect(report.lowercased().contains("only erases"))
        #expect(report.lowercased().contains("nothing is written"))
    }

    @Test("Jede schreibende Methode nennt die Quelle")
    func writingStrategiesNameTheSource() {
        for strategy in [WriteStrategy.rawImage, .windowsFAT32, .macOSInstaller] {
            var ctx = context
            ctx.strategy = strategy
            let report = DiagnosticsReport.render(context: ctx, entries: [entry])
            #expect(
                report.contains("Windows11_Client"),
                Comment(rawValue: "\(strategy.rawValue): Quelle fehlt")
            )
            #expect(
                !report.lowercased().contains("only erases"),
                Comment(rawValue: "\(strategy.rawValue): falscher Hinweis")
            )
        }
    }

    @Test("Die Zuordnung Methode→Quelle ist für alle Fälle entschieden")
    func everyStrategyIsClassified() {
        // Exhaustive, so a strategy added later cannot default to the wrong
        // answer silently.
        var usesSource = 0
        for strategy in WriteStrategy.allCases {
            if DiagnosticsReport.strategyUsesSource(strategy) { usesSource += 1 }
        }
        #expect(usesSource == WriteStrategy.allCases.count - 1)
        #expect(!DiagnosticsReport.strategyUsesSource(.eraseOnly))
    }

    // MARK: - Language

    @Test("Die Beschriftungen sind englisch")
    func labelsAreEnglish() {
        // Checked by output rather than by scanning for German words, which is
        // how the previous version slipped through.
        var ctx = context
        ctx.strategy = .windowsFAT32
        let report = DiagnosticsReport.render(
            context: ctx,
            entries: [entry],
            failure: BiscuitError(
                kind: .partitioningFailed,
                message: "m", remedy: "r", diagnostics: "d"
            )
        )
        for label in ["Target:", "Source:", "Method:", "ERROR ", "REMEDY:", "DIAGNOSTICS:"] {
            #expect(report.contains(label), Comment(rawValue: "\(label) fehlt"))
        }
        for german in ["Ziel:", "Quelle:", "Methode:", "FEHLER ", "ABHILFE:", "DIAGNOSE:"] {
            #expect(!report.contains(german), Comment(rawValue: "\(german) ist zurück"))
        }
    }

    // MARK: - Shape

    @Test("Version, System, Protokoll und Fehler erscheinen vollständig")
    func reportIsComplete() {
        let failure = BiscuitError(
            kind: .partitioningFailed,
            message: "Partitionieren fehlgeschlagen.",
            remedy: "Abhilfetext",
            diagnostics: "errno 1"
        )
        let report = DiagnosticsReport.render(
            context: context, entries: [entry], failure: failure
        )
        #expect(report.contains("Biscuit 0.1.0-rc.5 (11)"))
        #expect(report.contains("macOS Version 27.0.1"))
        #expect(report.contains("Flex Line disk4"))
        #expect(report.contains("INFO app: starting erase_only"))
        #expect(report.contains("partitioningFailed"))
        #expect(report.contains("errno 1"))
    }

    @Test("Ohne Fehler erscheint kein Fehlerabschnitt")
    func noFailureSection() {
        let report = DiagnosticsReport.render(context: context, entries: [entry])
        #expect(!report.contains("ERROR "))
        #expect(!report.contains("REMEDY:"))
    }

    @Test("Zeitstempel sind unabhängig von der Systemsprache")
    func timestampsAreStable() {
        // A report that formats differently per locale is harder to compare
        // across two users reporting the same fault.
        let report = DiagnosticsReport.render(
            context: context, entries: [entry], timeZone: TimeZone(identifier: "UTC")
        )
        #expect(report.contains("[00:00:00.000]"))
    }
}

/// The same contradiction, flagged in the interface before anything is erased.
@Suite("Oberfläche: Quelle bei „nur löschen“")
struct EraseOnlySourceWarningTests {
    private static func source(_ relative: String) -> String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: candidate) {
                return String(decoding: data, as: UTF8.self)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Die Optionen warnen, wenn die Methode die Quelle ignoriert")
    func optionsWarn() throws {
        let text = try #require(
            Self.source("Sources/BiscuitApp/Views/OptionsSection.swift"),
            "OptionsSection nicht gefunden"
        )
        #expect(text.contains("optionsEraseIgnoresSource"))
        #expect(text.contains("coordinator.source != nil"))
    }

    @Test("Die Bestätigung benennt die ungenutzte Quelle")
    func confirmationMentionsIt() throws {
        // The last moment to notice, and the one place the user definitely
        // looks before agreeing to erase a disk.
        let text = try #require(
            Self.source("Sources/BiscuitApp/Views/ConfirmationSheet.swift")
        )
        #expect(text.contains("confirmSourceUnused"))
    }
}

/// Die Antwortdatei muss im Bericht stehen.
///
/// Ein Medium wurde mit einer `autounattend.xml` beschrieben, die der Nutzer
/// nicht angefordert hatte: er hatte die Vorlage einmal ausprobiert, und sie
/// blieb danach an jedem weiteren Auftrag hängen, weil eine neue Quelle sie
/// nicht räumte. Die Windows-Installation brach daran ab.
///
/// Sein eingefügtes Protokoll gab davon keinen Hinweis — die Zeile stand nur im
/// Protokoll des Helfers, an das man ohne Root nicht herankommt. Ein
/// Diagnosebericht, der die wirksamen Eingaben verschweigt, kostet genau die
/// Zeit, die er sparen soll.
@Suite("Diagnosebericht: Antwortdatei")
struct DiagnosticsReportAnswerFileTests {
    private func context(
        strategy: WriteStrategy,
        answerFile: String?
    ) -> DiagnosticsReport.Context {
        .init(
            appVersion: "0.1.0", appBuild: "1", osVersion: "27.0.1",
            target: "disk4", source: "win.iso", strategy: strategy,
            answerFile: answerFile
        )
    }

    @Test("Eine mitgeschriebene Antwortdatei wird genannt")
    func answerFileAppears() {
        let report = DiagnosticsReport.render(
            context: context(strategy: .windowsFAT32, answerFile: "autounattend.xml · 1,6 KB"),
            entries: []
        )
        #expect(report.contains("Answer file:"))
        #expect(report.contains("autounattend.xml"))
    }

    @Test("Ohne Antwortdatei erscheint keine Zeile")
    func absentWhenNone() {
        let report = DiagnosticsReport.render(
            context: context(strategy: .windowsFAT32, answerFile: nil), entries: []
        )
        #expect(!report.contains("Answer file:"))
    }

    @Test("Bei „nur löschen“ wird keine Antwortdatei behauptet")
    func notClaimedForEraseOnly() {
        // Die Methode schreibt nichts, also auch keine Antwortdatei.
        let report = DiagnosticsReport.render(
            context: context(strategy: .eraseOnly, answerFile: "autounattend.xml"), entries: []
        )
        #expect(!report.contains("Answer file:"))
    }
}

/// Eine neue Quelle beginnt einen neuen Auftrag.
@Suite("Antwortdatei: Lebensdauer")
struct AnswerFileLifetimeTests {
    @Test("selectSource verwirft eine vorhandene Antwortdatei")
    func selectSourceDiscardsIt() throws {
        // Am Quelltext geprüft, weil JobCoordinator im App-Target liegt.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: String?
        for _ in 0..<5 {
            let candidate = directory
                .appendingPathComponent("Sources/BiscuitApp/Services/JobCoordinator.swift")
            if let data = try? Data(contentsOf: candidate) {
                source = String(decoding: data, as: UTF8.self)
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        let text = try #require(source, "JobCoordinator nicht gefunden")

        // Die Zuweisung muss im Erfolgspfad von selectSource stehen, also nach
        // `source = inspected`.
        let assign = try #require(text.range(of: "source = inspected"))
        let clear = try #require(
            text.range(of: "answerFile = nil", range: assign.upperBound..<text.endIndex),
            "Antwortdatei wird beim Quellenwechsel nicht geräumt"
        )
        let nextFunction = text.range(of: "\n    func ", range: assign.upperBound..<text.endIndex)
        if let nextFunction {
            #expect(
                clear.lowerBound < nextFunction.lowerBound,
                "Räumen steht außerhalb von selectSource"
            )
        }
        #expect(text.contains("answer file discarded"), "Verwerfen wird nicht protokolliert")
    }
}
