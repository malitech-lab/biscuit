import Foundation
import Testing
@testable import BiscuitKit

/// The privileged side must not believe what the unprivileged side computed.
///
/// `AnswerFile.findings` is part of the `Codable` representation, so it crosses
/// the socket with the contents, and `isUsable` is derived from it. A helper
/// that checks `isUsable` is therefore asking the client whether the client's
/// own file is acceptable — which is exactly what `WindowsMediaBuilder` did,
/// beneath a comment stating that it re-validated instead of trusting the app.
///
/// These tests pin the corrected behaviour: the verdict comes from the bytes.
@Suite("Antwortdatei: Vertrauensgrenze")
struct AnswerFileTrustTests {
    /// Well-formed and genuinely acceptable.
    private static let valid = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="oobeSystem"/>
        </unattend>
        """.utf8)

    @Test("Mitgesandte Befunde entscheiden nicht über die Annahme")
    func forgedFindingsAreIgnored() throws {
        // A client declaring a broken file clean.
        let forged = AnswerFile(
            originalFileName: "autounattend.xml",
            contents: Data("<this is not xml at all".utf8),
            findings: []
        )
        // The property the helper used to consult says it is fine.
        #expect(forged.isUsable, "Annahme des Tests hinfällig")
        // The bytes say otherwise, and that is what decides.
        #expect(throws: BiscuitError.self) { try forged.assertWritable() }
    }

    @Test("Ein falscher Wurzelknoten wird trotz leerer Befunde abgelehnt")
    func forgedWrongRootIsRejected() throws {
        let forged = AnswerFile(
            originalFileName: "autounattend.xml",
            contents: Data(#"<configuration xmlns="urn:x"/>"#.utf8),
            findings: []
        )
        #expect(forged.isUsable)
        let error = try #require(throws: BiscuitError.self) { try forged.assertWritable() }
        #expect(error.diagnostics?.contains("wrong_root_element") == true)
    }

    @Test("Eine leere Datei wird trotz leerer Befunde abgelehnt")
    func forgedEmptyIsRejected() throws {
        let forged = AnswerFile(
            originalFileName: "autounattend.xml", contents: Data(), findings: []
        )
        #expect(forged.isUsable)
        let error = try #require(throws: BiscuitError.self) { try forged.assertWritable() }
        #expect(error.diagnostics?.contains("empty") == true)
    }

    @Test("Die Größengrenze gilt unabhängig von jedem Befund")
    func sizeLimitIsIndependent() throws {
        // Bounds work rather than describing the file, so it is checked against
        // the raw byte count before anything is parsed.
        let oversized = AnswerFile(
            originalFileName: "autounattend.xml",
            contents: Data(repeating: 0x41, count: AnswerFile.maximumSizeBytes + 1),
            findings: []
        )
        let error = try #require(throws: BiscuitError.self) { try oversized.assertWritable() }
        #expect(error.diagnostics?.contains("bytes") == true)
        #expect(error.diagnostics?.contains("limit") == true)
    }

    @Test("Eine gültige Datei wird auch mit erfundenen Sperrbefunden angenommen")
    func forgedBlockingFindingsDoNotRejectValidFile() throws {
        // The reverse direction matters too: the client cannot cause a
        // rejection by claiming a problem that is not in the bytes, because
        // then a bug in the app would break a perfectly good medium.
        let misreported = AnswerFile(
            originalFileName: "autounattend.xml",
            contents: Self.valid,
            findings: [.init(kind: .notXML, severity: .blocking)]
        )
        #expect(!misreported.isUsable, "Annahme des Tests hinfällig")
        try misreported.assertWritable()
    }

    @Test("Die Neuprüfung leitet die Befunde aus den Bytes ab")
    func reinspectionDerivesFindings() {
        let forged = AnswerFile(
            originalFileName: "meine.xml",
            contents: Data(#"<unattend xmlns="urn:schemas-microsoft-com:unattend"/>"#.utf8),
            findings: []
        )
        let verdict = forged.independentlyInspected()
        // The renamed finding appears because the inspector derives it rather
        // than copying it, which is evidence the scan really ran.
        #expect(verdict.findings.contains { $0.kind == .renamed })
        #expect(verdict.isUsable)
    }

    @Test("Geheimnisse werden ebenfalls neu erkannt, nicht übernommen")
    func secretsAreRediscovered() {
        let forged = AnswerFile(
            originalFileName: "autounattend.xml",
            contents: Data("""
                <unattend xmlns="urn:schemas-microsoft-com:unattend">
                  <settings pass="oobeSystem">
                    <ProductKey>AAAAA-BBBBB-CCCCC-DDDDD-EEEEE</ProductKey>
                  </settings>
                </unattend>
                """.utf8),
            findings: []
        )
        #expect(!forged.containsSecrets, "Annahme des Tests hinfällig")
        #expect(forged.independentlyInspected().containsSecrets)
        // Secrets never block, so the file is still writable.
        try? forged.assertWritable()
    }

    @Test("Eine erzeugte Vorlage besteht die Prüfung des Helfers")
    func generatedTemplatePassesHelperCheck() throws {
        // Generated files take the same route as dropped ones, so they face
        // the same gate.
        let answer = try AnswerFileTemplate(
            bypassHardwareChecks: true,
            localAccount: .init(name: "Nutzer", password: "pw")
        ).build()
        try answer.assertWritable()
    }

    @Test("Der Weg über die Leitung ändert das Urteil nicht")
    func verdictSurvivesTransport() throws {
        let answer = try AnswerFileTemplate(skipSetupPages: true).build()
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
        let received = try #require(decoded.answerFile)
        try received.assertWritable()
    }
}

/// Confirms the helper actually calls the independent check.
///
/// `WindowsMediaBuilder` lives in an executable target the test target cannot
/// import, so the call site is checked in the source. Crude, but it is the
/// difference between having the function and using it — and the bug this
/// replaced was precisely a correct-looking comment above the wrong check.
@Suite("Antwortdatei: Aufrufstelle im Helfer")
struct AnswerFileHelperCallSiteTests {
    private static var helperSource: String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent(
                "Sources/BiscuitHelper/Operations/WindowsMediaBuilder.swift"
            )
            if let data = try? Data(contentsOf: candidate) {
                return String(decoding: data, as: UTF8.self)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Der Helfer prüft die Bytes neu")
    func helperCallsAssertWritable() throws {
        let source = try #require(Self.helperSource, "Helferquelle nicht gefunden")
        #expect(source.contains("assertWritable()"))
    }

    @Test("Der Helfer verlässt sich nicht auf isUsable")
    func helperDoesNotTrustIsUsable() throws {
        // `isUsable` is derived from findings that came over the socket, so on
        // the privileged side it means nothing.
        let source = try #require(Self.helperSource)
        #expect(
            !source.contains("answerFile.isUsable"),
            "Helfer stützt sich wieder auf übertragene Befunde"
        )
    }
}
