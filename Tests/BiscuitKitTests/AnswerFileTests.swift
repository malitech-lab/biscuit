import Foundation
import Testing
@testable import BiscuitKit

/// Validation of Windows Setup answer files.
///
/// Every blocking case here is one that Windows Setup would otherwise fail on
/// twenty minutes into an installation, on a different machine, with a message
/// that does not name the cause. Catching them before the stick is written is
/// the entire point.
@Suite("Antwortdatei")
struct AnswerFileTests {
    private let inspector = AnswerFileInspector()

    private func inspect(_ xml: String, name: String = "autounattend.xml") -> AnswerFile {
        inspector.inspect(fileName: name, contents: Data(xml.utf8))
    }

    private static let minimalValid = """
        <?xml version="1.0" encoding="utf-8"?>
        <unattend xmlns="urn:schemas-microsoft-com:unattend">
          <settings pass="oobeSystem">
            <component name="Microsoft-Windows-Shell-Setup"
                       processorArchitecture="amd64"
                       publicKeyToken="31bf3856ad364e35"
                       language="neutral"
                       versionScope="nonSxS">
              <OOBE>
                <HideEULAPage>true</HideEULAPage>
              </OOBE>
            </component>
          </settings>
        </unattend>
        """

    // MARK: - Structure

    @Test("Eine gültige Antwortdatei wird akzeptiert")
    func validFileAccepted() {
        let file = inspect(Self.minimalValid)
        #expect(file.isUsable)
        #expect(!file.containsSecrets)
        #expect(file.findings.isEmpty, "unerwartete Befunde: \(file.findings.map(\.kind.rawValue))")
    }

    @Test("Kein XML wird blockiert")
    func malformedXMLBlocked() {
        // The single most common mistake: a truncated download or a file edited
        // in a word processor.
        let file = inspect("<unattend><settings></unattend>")
        #expect(!file.isUsable)
        #expect(file.findings.contains { $0.kind == .notXML && $0.severity == .blocking })
    }

    @Test("Falsches Wurzelelement wird blockiert")
    func wrongRootBlocked() {
        // Valid XML, just not an answer file — someone dropped the wrong file.
        let file = inspect("""
            <?xml version="1.0"?>
            <configuration><setting name="x">1</setting></configuration>
            """)
        #expect(!file.isUsable)
        let finding = file.findings.first { $0.kind == .wrongRootElement }
        #expect(finding?.severity == .blocking)
        #expect(finding?.detail == "configuration")
    }

    @Test("Fehlender Namensraum warnt nur, blockiert aber nicht")
    func missingNamespaceWarnsOnly() {
        // Setup is lenient here, and refusing a file that would have worked is
        // its own kind of failure.
        let file = inspect("""
            <?xml version="1.0"?>
            <unattend><settings pass="oobeSystem"/></unattend>
            """)
        #expect(file.isUsable, "fehlender Namensraum darf nicht blockieren")
        #expect(file.findings.contains { $0.kind == .missingNamespace && $0.severity == .warning })
    }

    @Test("Leere Datei wird blockiert")
    func emptyBlocked() {
        let file = inspector.inspect(fileName: "autounattend.xml", contents: Data())
        #expect(!file.isUsable)
        #expect(file.findings.contains { $0.kind == .empty })
    }

    @Test("Zu große Datei wird blockiert, ohne sie zu parsen")
    func oversizedBlocked() {
        // Guards the IPC frame as much as the user: the request travels as JSON
        // through a socket with a 4 MiB cap.
        let payload = Data(repeating: 0x20, count: AnswerFile.maximumSizeBytes + 1)
        let file = inspector.inspect(fileName: "autounattend.xml", contents: payload)
        #expect(!file.isUsable)
        #expect(file.findings.contains { $0.kind == .tooLarge })
        #expect(file.findings.count == 1, "bei Übergröße soll nicht zusätzlich geparst werden")
    }

    @Test("Abweichender Dateiname wird als Hinweis vermerkt")
    func renamedFileNoted() {
        // Written as autounattend.xml regardless, but the user should know their
        // file was renamed rather than wonder why "unattend.xml" is not on the stick.
        let file = inspect(Self.minimalValid, name: "meine-config.xml")
        #expect(file.isUsable)
        let finding = file.findings.first { $0.kind == .renamed }
        #expect(finding?.severity == .info)
        #expect(finding?.detail == AnswerFile.standardFileName)
    }

    @Test("Standardname erzeugt keinen Hinweis")
    func standardNameSilent() {
        #expect(!inspect(Self.minimalValid, name: "AutoUnattend.XML").findings
            .contains { $0.kind == .renamed })
    }

    // MARK: - Secrets

    @Test("Klartext-Passwort wird erkannt")
    func passwordDetected() {
        let file = inspect("""
            <?xml version="1.0"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend">
              <settings pass="oobeSystem">
                <UserAccounts>
                  <AdministratorPassword>
                    <Value>hunter2</Value>
                    <PlainText>true</PlainText>
                  </AdministratorPassword>
                </UserAccounts>
              </settings>
            </unattend>
            """)
        #expect(file.isUsable, "Secrets dürfen nicht blockieren, nur warnen")
        #expect(file.containsSecrets)
        #expect(file.findings.contains { $0.kind == .containsPassword })
    }

    @Test("Product Key wird erkannt")
    func productKeyDetected() {
        let file = inspect("""
            <?xml version="1.0"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend">
              <settings pass="specialize">
                <ProductKey>XXXXX-XXXXX-XXXXX-XXXXX-XXXXX</ProductKey>
              </settings>
            </unattend>
            """)
        #expect(file.containsSecrets)
        #expect(file.findings.contains { $0.kind == .containsProductKey })
    }

    @Test("Domänen-Anmeldedaten werden erkannt")
    func domainCredentialsDetected() {
        let file = inspect("""
            <?xml version="1.0"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend">
              <settings pass="specialize">
                <Credentials>
                  <Domain>example.com</Domain>
                  <Username>join</Username>
                  <Password>s3cret</Password>
                </Credentials>
              </settings>
            </unattend>
            """)
        #expect(file.containsSecrets)
        #expect(file.findings.contains { $0.kind == .containsDomainCredentials })
    }

    @Test("Leere Secret-Elemente lösen keine Warnung aus")
    func emptySecretElementsIgnored() {
        // A template with the fields present but blank is common and carries
        // nothing worth warning about; warning anyway would train people to
        // ignore the warning.
        let file = inspect("""
            <?xml version="1.0"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend">
              <settings pass="oobeSystem">
                <ProductKey></ProductKey>
                <Password>   </Password>
              </settings>
            </unattend>
            """)
        #expect(!file.containsSecrets, "leere Felder sollten nicht warnen")
    }

    @Test("Ohne Secrets keine Secret-Warnung")
    func noFalsePositives() {
        #expect(!inspect(Self.minimalValid).containsSecrets)
    }

    @Test("Bei blockierender Struktur wird nicht nach Secrets gesucht")
    func noSecretScanOnBrokenFile() {
        // Warnings about an unrelated document would be noise.
        let file = inspect("<config><Password>x</Password></config>")
        #expect(!file.isUsable)
        #expect(!file.containsSecrets)
    }

    // MARK: - Transport

    @Test("Antwortdatei überlebt die JSON-Codierung des Auftrags")
    func survivesJobEncoding() throws {
        // The file travels inside JobRequest over the socket, so a Codable slip
        // would strip it silently.
        let file = inspect(Self.minimalValid)
        let request = JobRequest(
            strategy: .windowsFAT32,
            targetBSDName: "disk9",
            expectedTargetSizeBytes: .gibibytes(16),
            source: .mountedDirectory(path: "/Volumes/X", displayName: "x.iso"),
            volumeLabel: "WIN",
            partitionScheme: .gpt,
            filesystem: .fat32,
            verifyAfterWrite: false,
            answerFile: file
        )

        let data = try IPCProtocol.makeEncoder().encode(request)
        let decoded = try IPCProtocol.makeDecoder().decode(JobRequest.self, from: data)

        #expect(decoded.answerFile?.contents == file.contents)
        #expect(decoded.answerFile?.originalFileName == file.originalFileName)
        #expect(decoded.answerFile?.isUsable == true)
    }

    @Test("Eine maximal große Antwortdatei passt in einen IPC-Frame")
    func fitsInFrame() throws {
        let payload = Data(repeating: 0x41, count: AnswerFile.maximumSizeBytes)
        let file = AnswerFile(originalFileName: "a.xml", contents: payload, findings: [])
        let request = JobRequest(
            strategy: .windowsFAT32,
            targetBSDName: "disk9",
            expectedTargetSizeBytes: .gibibytes(16),
            source: .mountedDirectory(path: "/Volumes/X", displayName: "x.iso"),
            volumeLabel: "WIN",
            partitionScheme: .gpt,
            filesystem: .fat32,
            verifyAfterWrite: false,
            answerFile: file
        )
        let encoded = try IPCProtocol.makeEncoder().encode(request)
        // Base64 inflates by about a third; the cap has to leave room for that.
        #expect(encoded.count < IPCProtocol.maxFrameBytes,
                "codiert \(encoded.count) Bytes, Limit \(IPCProtocol.maxFrameBytes)")
    }

    @Test("Eine Antwortdatei wird nie protokolliert")
    func neverLogged() {
        // The contents routinely hold a password in plain text. The only
        // description the type offers must not include them.
        let secretValue = "correct-horse-battery-staple"
        let file = inspect("""
            <?xml version="1.0"?>
            <unattend xmlns="urn:schemas-microsoft-com:unattend">
              <settings pass="oobeSystem"><Password>\(secretValue)</Password></settings>
            </unattend>
            """)
        #expect(!file.displaySummary.contains(secretValue))
        #expect(!"\(file.findings)".contains(secretValue))
    }
}
