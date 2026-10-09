import Foundation
import Testing
@testable import BiscuitKit

@Suite("Antwortdatei-Vorlagen")
struct AnswerFileTemplateTests {

    // MARK: - The central guarantee

    /// Every combination of options must survive the inspector that guards
    /// hand-written files.
    ///
    /// This is the one test that matters most. A renderer bug produces XML that
    /// Windows Setup *silently ignores* — no error, no warning, just a normal
    /// installation that does none of what was asked. Holding generated files
    /// to the same standard as user-supplied ones is what turns that into a
    /// caught failure.
    @Test("Jede Optionskombination besteht die vorhandene Prüfung")
    func everyCombinationValidates() throws {
        var checked = 0
        // 2^4 = 16 flag combinations, each with and without an account and a
        // locale, across both architectures: 128 documents.
        for bits in 0..<16 {
            for account in [nil, AnswerFileTemplate.LocalAccount(name: "Nutzer", password: "pw")] {
                for locale in [nil, "de-DE"] {
                    for architecture in [WindowsArchitecture.x64, .arm64] {
                        let template = AnswerFileTemplate(
                            architecture: architecture,
                            bypassHardwareChecks: bits & 1 != 0,
                            bypassMicrosoftAccount: bits & 2 != 0,
                            skipSetupPages: bits & 4 != 0,
                            declineTelemetry: bits & 8 != 0,
                            localAccount: account,
                            locale: locale
                        )
                        let answer = try template.build()
                        #expect(
                            answer.isUsable,
                            "bits=\(bits) account=\(account != nil) locale=\(locale ?? "-") arch=\(architecture.displayName)"
                        )
                        // No blocking finding, and in particular never `.notXML`.
                        #expect(!answer.findings.contains { $0.severity == .blocking })
                        checked += 1
                    }
                }
            }
        }
        #expect(checked == 128, "nicht alle Kombinationen geprüft: \(checked)")
    }

    @Test("Auch die leere Vorlage ergibt ein gültiges Dokument")
    func emptyTemplateIsValid() throws {
        // Produces a bare `<unattend/>`, which changes nothing — but must still
        // be well-formed rather than an empty file the inspector blocks.
        let template = AnswerFileTemplate()
        #expect(template.isEmpty)
        let answer = try template.build()
        #expect(answer.isUsable)
        #expect(answer.contents.count > 0)
    }

    // MARK: - Content

    @Test("Die Hardware-Umgehung schreibt alle fünf LabConfig-Werte")
    func hardwareBypassWritesAllValues() throws {
        // Omitting one leaves that single check active, and the install fails
        // at exactly the point the user was trying to get past.
        let xml = AnswerFileTemplate(bypassHardwareChecks: true).render()
        for value in AnswerFileTemplate.hardwareBypassValues {
            #expect(xml.contains(value), "\(value) fehlt")
        }
        #expect(xml.contains(#"pass="windowsPE""#), "falscher Durchlauf")
        // The checks happen before files are copied, so a later pass is useless.
        #expect(!xml.contains(#"<settings pass="specialize">"#) || xml.contains("BypassNRO"))
    }

    @Test("Die Befehlsreihenfolge ist lückenlos und beginnt bei 1")
    func commandOrderIsContiguous() throws {
        // Windows Setup runs RunSynchronousCommand by <Order>; a duplicate or a
        // gap makes it skip commands.
        let xml = AnswerFileTemplate(bypassHardwareChecks: true).render()
        var orders: [Int] = []
        var rest = Substring(xml)
        while let start = rest.range(of: "<Order>"),
              let end = rest.range(of: "</Order>", range: start.upperBound..<rest.endIndex) {
            if let value = Int(rest[start.upperBound..<end.lowerBound]) { orders.append(value) }
            rest = rest[end.upperBound...]
        }
        #expect(orders == Array(1...AnswerFileTemplate.hardwareBypassValues.count))
    }

    @Test("Die Architektur landet im processorArchitecture-Attribut")
    func architectureIsApplied() throws {
        // Setup matches this strictly: an amd64 answer file is ignored outright
        // on an ARM64 install, with no diagnostic anywhere.
        let x64 = AnswerFileTemplate(architecture: .x64, bypassHardwareChecks: true).render()
        #expect(x64.contains(#"processorArchitecture="amd64""#))
        #expect(!x64.contains(#"processorArchitecture="arm64""#))

        let arm = AnswerFileTemplate(architecture: .arm64, bypassHardwareChecks: true).render()
        #expect(arm.contains(#"processorArchitecture="arm64""#))
        #expect(!arm.contains(#"processorArchitecture="amd64""#))
    }

    @Test("Eine nicht unterstützte Architektur wird abgelehnt, nicht geraten")
    func unsupportedArchitectureIsRejected() {
        // Writing a wrong value would make Setup ignore the file silently,
        // which is the worst outcome available.
        for architecture in [WindowsArchitecture.ia64, .mips, .powerPC, .alpha, .arm] {
            let template = AnswerFileTemplate(
                architecture: architecture, bypassHardwareChecks: true
            )
            #expect(template.processorArchitecture == nil)
            #expect(throws: BiscuitError.self) { _ = try template.build() }
        }
    }

    @Test("Telemetrie wird abgelehnt, nicht nur empfohlen abgeschwächt")
    func telemetryIsDeclined() throws {
        // ProtectYourPC=1 accepts the recommended settings; only 3 declines
        // everything optional.
        let xml = AnswerFileTemplate(declineTelemetry: true).render()
        #expect(xml.contains("<ProtectYourPC>3</ProtectYourPC>"))
        #expect(!xml.contains("<ProtectYourPC>1</ProtectYourPC>"))
    }

    @Test("Ohne Optionen entstehen keine leeren settings-Blöcke")
    func noEmptySettingsBlocks() throws {
        let xml = AnswerFileTemplate().render()
        #expect(!xml.contains("<settings"), "leerer settings-Block erzeugt")
        #expect(xml.contains("<unattend"))
    }

    // MARK: - Escaping

    @Test("Sonderzeichen im Kontonamen zerstören das Dokument nicht")
    func specialCharactersAreEscaped() throws {
        // The account name comes from a text field. An unescaped `&` or `<`
        // yields XML that `XMLDocument` refuses — and before the
        // build-then-validate step, that meant a medium whose answer file
        // Setup ignores.
        let template = AnswerFileTemplate(
            localAccount: .init(name: #"Tom & <Jerry> "Co" 'x'"#, password: #"a&b<c>"#)
        )
        let answer = try template.build()
        #expect(answer.isUsable, "Dokument durch Sonderzeichen unbrauchbar")

        let xml = String(decoding: answer.contents, as: UTF8.self)
        #expect(xml.contains("Tom &amp; &lt;Jerry&gt;"))
        #expect(!xml.contains("<Jerry>"), "unmaskiertes Element eingeschmuggelt")
        #expect(xml.contains("a&amp;b&lt;c&gt;"))
    }

    @Test("Ein eingeschmuggeltes Element bleibt Text")
    func injectionStaysText() throws {
        // The failure this prevents: a name that closes the surrounding element
        // and opens new ones would let arbitrary setup commands be injected.
        let evil = "</Name></LocalAccount></LocalAccounts></UserAccounts>"
            + "<RunSynchronousCommand><Path>format c:</Path></RunSynchronousCommand>"
        let answer = try AnswerFileTemplate(localAccount: .init(name: evil)).build()
        #expect(answer.isUsable)

        let xml = String(decoding: answer.contents, as: UTF8.self)
        #expect(!xml.contains("<Path>format c:</Path>"), "Befehl eingeschmuggelt")
        #expect(xml.contains("&lt;/Name&gt;"))

        // And the parsed document really contains no such command.
        let document = try XMLDocument(data: answer.contents, options: [])
        let paths = try document.nodes(forXPath: "//Path")
        #expect(!paths.contains { $0.stringValue?.contains("format") == true })
    }

    @Test("Steuerzeichen werden entfernt, nicht kodiert")
    func controlCharactersAreDropped() throws {
        // XML 1.0 cannot represent them at all, so encoding them would still
        // produce a document the parser rejects.
        let answer = try AnswerFileTemplate(
            localAccount: .init(name: "Nutzer\u{0}\u{1}\u{8}Name")
        ).build()
        #expect(answer.isUsable)
        let xml = String(decoding: answer.contents, as: UTF8.self)
        #expect(xml.contains("NutzerName"))
    }

    @Test("Umlaute und Nicht-ASCII bleiben erhalten")
    func unicodeSurvives() throws {
        let answer = try AnswerFileTemplate(localAccount: .init(name: "Jörg Müller 日本")).build()
        let xml = String(decoding: answer.contents, as: UTF8.self)
        #expect(xml.contains("Jörg Müller 日本"))
        #expect(answer.isUsable)
    }

    // MARK: - Secrets

    @Test("Ein gesetztes Kennwort wird als Geheimnis erkannt")
    func passwordIsFlagged() throws {
        // Deliberately not suppressed for generated files: the password really
        // does end up in plain text on the medium, and the warning is the only
        // place that says so.
        let answer = try AnswerFileTemplate(
            localAccount: .init(name: "Nutzer", password: "hunter2")
        ).build()
        #expect(answer.containsSecrets)
        #expect(answer.isUsable, "Geheimnisse dürfen nicht blockieren")
        #expect(answer.findings.contains { $0.kind == .containsPassword })
    }

    @Test("Ein Konto ohne Kennwort löst keine Geheimniswarnung aus")
    func accountWithoutPasswordIsClean() throws {
        let answer = try AnswerFileTemplate(localAccount: .init(name: "Nutzer")).build()
        #expect(!answer.containsSecrets)
        let xml = String(decoding: answer.contents, as: UTF8.self)
        #expect(!xml.contains("<Password>"), "leeres Kennwortelement geschrieben")
    }

    @Test("Das Kennwort steht nicht in der Zusammenfassung")
    func passwordNotInSummary() throws {
        let answer = try AnswerFileTemplate(
            localAccount: .init(name: "Nutzer", password: "correct-horse-battery-staple")
        ).build()
        #expect(!answer.displaySummary.contains("correct-horse"))
        #expect(!"\(answer.findings)".contains("correct-horse"))
    }

    // MARK: - Locale

    @Test("Plausible Sprachkennungen werden übernommen")
    func plausibleLocalesAccepted() throws {
        for locale in ["de", "de-DE", "en-US", "sr-Latn-RS"] {
            #expect(AnswerFileTemplate.isPlausibleLocale(locale), "\(locale) abgelehnt")
            let xml = AnswerFileTemplate(locale: locale).render()
            #expect(xml.contains("<UILanguage>\(locale)</UILanguage>"), "\(locale) fehlt")
        }
    }

    @Test("Unplausible Sprachkennungen werden verworfen, nicht geschrieben")
    func implausibleLocalesDropped() throws {
        // A malformed locale makes Setup fall back silently, so writing it
        // would only hide the mistake.
        for locale in ["", "x", "de-DE-DE-DE", "de_DE", "../../etc", "<de>", "12-34"] {
            #expect(!AnswerFileTemplate.isPlausibleLocale(locale), "\(locale) akzeptiert")
            let xml = AnswerFileTemplate(locale: locale).render()
            #expect(!xml.contains("<UILanguage>"), "\(locale) wurde geschrieben")
        }
    }

    // MARK: - Shape

    @Test("Der Namensraum entspricht dem, den die Prüfung erwartet")
    func namespaceMatchesInspector() throws {
        // Taken from the same constant the inspector checks against, so the two
        // cannot drift apart.
        let answer = try AnswerFileTemplate(skipSetupPages: true).build()
        #expect(!answer.findings.contains { $0.kind == .missingNamespace })
        let xml = String(decoding: answer.contents, as: UTF8.self)
        #expect(xml.contains(AnswerFile.unattendNamespace))
    }

    @Test("Die Datei bleibt weit unter der Größengrenze")
    func staysWellUnderSizeLimit() throws {
        let answer = try AnswerFileTemplate(
            architecture: .x64,
            bypassHardwareChecks: true, bypassMicrosoftAccount: true,
            skipSetupPages: true, declineTelemetry: true,
            localAccount: .init(name: "Nutzer", password: "pw"), locale: "de-DE"
        ).build()
        #expect(answer.sizeBytes < 8 * 1024, "unerwartet groß: \(answer.sizeBytes)")
        #expect(!answer.findings.contains { $0.kind == .tooLarge })
    }

    @Test("Die Vorlage übersteht die Übertragung zum Helfer")
    func survivesTransport() throws {
        // Generated files take the same route as dropped ones, so the same
        // round trip has to hold.
        let answer = try AnswerFileTemplate(
            bypassHardwareChecks: true, localAccount: .init(name: "Nutzer")
        ).build()
        let request = JobRequest(
            strategy: .windowsFAT32,
            targetBSDName: "disk9",
            expectedTargetSizeBytes: .gibibytes(16),
            source: .mountedDirectory(path: "/Volumes/X", displayName: "x.iso"),
            volumeLabel: "WIN",
            partitionScheme: .gpt,
            filesystem: .fat32,
            verifyAfterWrite: false,
            answerFile: answer
        )
        let data = try IPCProtocol.makeEncoder().encode(request)
        let decoded = try IPCProtocol.makeDecoder().decode(JobRequest.self, from: data)
        #expect(decoded.answerFile?.contents == answer.contents)
        #expect(decoded.answerFile?.isUsable == true)
    }
}

/// Komponentenschema: welches Element in welche Komponente gehört.
///
/// Die erste Fassung schrieb `InputLocale`, `SystemLocale`, `UILanguage` und
/// `UserLocale` nach `Microsoft-Windows-Shell-Setup`. Sie gehören in
/// `Microsoft-Windows-International-Core`. Windows Setup prüft jede Komponente
/// gegen ihr Schema und bricht bei einem fremden Element den gesamten Durchlauf
/// ab — die Installation scheiterte dadurch reproduzierbar auf echter Hardware.
///
/// Durchgelassen hat es die eigene Prüfung, die Wurzelelement und Namensraum
/// kennt, aber keine Schemata. Der Test „jede Optionskombination besteht die
/// Prüfung" bestätigte damit nur, dass Erzeuger und Prüfer dieselbe Lücke
/// haben — eine geschlossene Schleife, die dritte in diesem Projekt.
@Suite("Antwortdatei: Komponentenschema")
struct AnswerTemplateSchemaTests {
    @Test("Spracheinstellungen stehen in International-Core")
    func localeGoesToInternationalCore() throws {
        let xml = AnswerFileTemplate(locale: "de-DE").render()
        let document = try XMLDocument(data: Data(xml.utf8), options: [])

        for element in ["InputLocale", "SystemLocale", "UILanguage", "UserLocale"] {
            let nodes = try document.nodes(forXPath: "//*[local-name()='\(element)']")
            #expect(nodes.count == 1, Comment(rawValue: "\(element) fehlt oder doppelt"))
            let parent = nodes.first?.parent as? XMLElement
            let component = parent?.attribute(forName: "name")?.stringValue
            #expect(
                component == "Microsoft-Windows-International-Core",
                Comment(rawValue: "\(element) steht in \(component ?? "?")")
            )
        }
    }

    @Test("OOBE und Konten stehen in Shell-Setup")
    func oobeStaysInShellSetup() throws {
        let xml = AnswerFileTemplate(
            skipSetupPages: true, localAccount: .init(name: "Nutzer")
        ).render()
        let document = try XMLDocument(data: Data(xml.utf8), options: [])

        for element in ["OOBE", "UserAccounts"] {
            let nodes = try document.nodes(forXPath: "//*[local-name()='\(element)']")
            let parent = nodes.first?.parent as? XMLElement
            #expect(
                parent?.attribute(forName: "name")?.stringValue == "Microsoft-Windows-Shell-Setup",
                Comment(rawValue: "\(element) in falscher Komponente")
            )
        }
    }

    @Test("Keine Optionskombination verletzt das Schema")
    func noCombinationViolatesSchema() throws {
        // Dieselbe Erschöpfung wie beim Prüfungstest — diesmal aber gegen die
        // Komponentenzuordnung, die der Prüfung fehlte.
        var checked = 0
        for bits in 0..<16 {
            for account in [nil, AnswerFileTemplate.LocalAccount(name: "N", password: "p")] {
                for locale in [nil, "de-DE", "en-US"] {
                    let template = AnswerFileTemplate(
                        architecture: .x64,
                        bypassHardwareChecks: bits & 1 != 0,
                        bypassMicrosoftAccount: bits & 2 != 0,
                        skipSetupPages: bits & 4 != 0,
                        declineTelemetry: bits & 8 != 0,
                        localAccount: account,
                        locale: locale
                    )
                    let violations = template.schemaViolations()
                    #expect(
                        violations.isEmpty,
                        Comment(rawValue: "bits=\(bits): \(violations.joined(separator: ", "))")
                    )
                    checked += 1
                }
            }
        }
        #expect(checked == 96)
    }

    @Test("Die Prüfung erkennt eine falsch platzierte Spracheinstellung")
    func checkCatchesMisplacement() {
        // Ohne diese Gegenprobe wäre nicht gezeigt, dass die Prüfung etwas
        // merkt — nur, dass sie schweigt.
        let owners = AnswerFileTemplate.elementOwners
        #expect(owners["UILanguage"] == "Microsoft-Windows-International-Core")
        #expect(owners["OOBE"] == "Microsoft-Windows-Shell-Setup")
        #expect(owners["UILanguage"] != owners["OOBE"], "beide Komponenten wären identisch")
    }

    @Test("Jede erzeugte Datei bleibt wohlgeformtes XML")
    func stillWellFormed() throws {
        let answer = try AnswerFileTemplate(
            bypassHardwareChecks: true, bypassMicrosoftAccount: true,
            skipSetupPages: true, declineTelemetry: true,
            localAccount: .init(name: "Nutzer"), locale: "de-DE"
        ).build()
        let document = try XMLDocument(data: answer.contents, options: [])
        // Zwei Komponenten im oobeSystem-Durchlauf, nicht eine.
        let components = try document.nodes(
            forXPath: "//*[local-name()='settings'][@pass='oobeSystem']/*[local-name()='component']"
        )
        #expect(components.count == 2, "erwartet International-Core und Shell-Setup")
    }
}
