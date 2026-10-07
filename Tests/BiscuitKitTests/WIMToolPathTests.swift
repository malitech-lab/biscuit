import Foundation
import Testing
@testable import BiscuitKit

/// The tool path is the executable of a process that runs as root.
///
/// `JobRequest.wimToolPath` is chosen by the unprivileged app and was passed
/// straight into `Process.executableURL` in the privileged helper, checked only
/// for `isExecutableFile`. Source paths in the same request have been checked
/// against an allow-list all along, for exactly this reason; the tool path was
/// simply never given the same treatment.
///
/// These tests pin the check. Several of them build their fixtures with
/// deliberately hostile shapes, because that is the only way to know the check
/// looks at what it claims to.
@Suite("Pfad des wimlib-Werkzeugs", .serialized)
struct WIMToolPathTests {
    /// A scratch directory plus a fake tool inside it.
    private struct Sandbox {
        let root: URL
        let binary: URL

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeSandbox(
        name: String = WIMTool.expectedToolName,
        directoryMode: Int = 0o755,
        fileMode: Int = 0o755
    ) throws -> Sandbox {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-tool-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        let binary = root.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        try FileManager.default.setAttributes(
            [.posixPermissions: fileMode], ofItemAtPath: binary.path
        )
        return Sandbox(root: root, binary: binary)
    }

    /// A helper executable placed next to the tool, as `bundle.sh` arranges.
    private func helperSibling(of sandbox: Sandbox) -> URL {
        sandbox.root.appendingPathComponent("biscuit-helper")
    }

    // MARK: - Accepting the legitimate cases

    @Test("Das mitgelieferte Werkzeug neben dem Helfer wird akzeptiert")
    func acceptsVendoredSibling() throws {
        // Scripts/bundle.sh puts wimlib-imagex next to biscuit-helper in
        // Contents/MacOS, so this is the packaged case.
        let sandbox = try makeSandbox()
        defer { sandbox.remove() }

        try WIMTool.validateToolPath(
            sandbox.binary.path, helperExecutable: helperSibling(of: sandbox)
        )
    }

    @Test("Die festen Homebrew-Pfade stehen auf der Allow-List")
    func homebrewPrefixesAreAllowed() {
        let allowed = WIMTool.allowedToolDirectories(helperExecutable: nil)
        #expect(allowed.contains("/opt/homebrew/bin/"))
        #expect(allowed.contains("/usr/local/bin/"))
        #expect(allowed.contains("/opt/local/bin/"))
    }

    @Test("Das Verzeichnis des Helfers steht an erster Stelle")
    func helperDirectoryComesFirst() {
        // Derived from the helper's own location, so the vendored copy wins
        // without the client naming it.
        let helper = URL(fileURLWithPath: "/Applications/Biscuit.app/Contents/MacOS/biscuit-helper")
        let allowed = WIMTool.allowedToolDirectories(helperExecutable: helper)
        #expect(allowed.first == "/Applications/Biscuit.app/Contents/MacOS/")
    }

    // MARK: - Rejecting the attack

    @Test("Ein beliebiger Pfad wird abgelehnt")
    func rejectsArbitraryPath() throws {
        // The gap itself: any executable the request happened to name was run
        // as root.
        let sandbox = try makeSandbox()
        defer { sandbox.remove() }

        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(sandbox.binary.path, helperExecutable: nil)
        }
        #expect(error.diagnostics?.contains("outside allowed directories") == true)
    }

    @Test("Ein fremder Programmname wird abgelehnt")
    func rejectsForeignBasename() throws {
        // Without this, anything placed in an allowed directory could be run.
        let sandbox = try makeSandbox(name: "evil")
        defer { sandbox.remove() }

        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(
                sandbox.binary.path, helperExecutable: helperSibling(of: sandbox)
            )
        }
        #expect(error.diagnostics?.contains("unexpected basename") == true)
    }

    @Test("Traversal wird abgelehnt, auch nach Normalisierung")
    func rejectsTraversal() throws {
        let path = "/opt/homebrew/bin/../../../tmp/\(WIMTool.expectedToolName)"
        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(path, helperExecutable: nil)
        }
        // Standardisation collapses the `..`, so the directory check is what
        // catches this one — which is the point of checking after
        // standardising rather than before.
        #expect(error.diagnostics != nil)
    }

    @Test("Ein verstecktes Traversal im Gerätepfad wird abgelehnt")
    func rejectsSurvivingTraversal() throws {
        // `standardizingPath` leaves `..` in place when the prefix is a
        // symlinked or non-existent root, so the explicit check matters.
        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(
                "/opt/homebrew/bin/./../bin/../../../usr/bin/\(WIMTool.expectedToolName)",
                helperExecutable: nil
            )
        }
        #expect(error.diagnostics != nil)
    }

    @Test("Eine weltschreibbare Datei wird abgelehnt")
    func rejectsWorldWritableFile() throws {
        // Anyone could replace it between the check and the launch, so its
        // current contents prove nothing.
        let sandbox = try makeSandbox(fileMode: 0o777)
        defer { sandbox.remove() }

        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(
                sandbox.binary.path, helperExecutable: helperSibling(of: sandbox)
            )
        }
        #expect(error.diagnostics?.contains("world-writable") == true)
    }

    @Test("Ein weltschreibbares Verzeichnis wird abgelehnt")
    func rejectsWorldWritableDirectory() throws {
        // The classic oversight: the binary itself is fine, but anyone can
        // swap it because they can write the directory.
        let sandbox = try makeSandbox(directoryMode: 0o777, fileMode: 0o755)
        defer { sandbox.remove() }

        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(
                sandbox.binary.path, helperExecutable: helperSibling(of: sandbox)
            )
        }
        #expect(error.diagnostics?.contains("world-writable") == true)
    }

    @Test("Gruppenschreibbar wird nach Gruppe beurteilt, nicht pauschal")
    func groupWritableIsJudgedByGroup() throws {
        // Die erste Fassung lehnte gruppenschreibbar pauschal ab. Das war
        // zugleich falsch und wirkungslos: Homebrew legt /opt/homebrew/bin als
        // `admin` mit Modus 775 an, also fiel jede reale Maschine darauf
        // herein — und die fest verdrahtete Ersatzliste führte denselben Pfad
        // danach ungeprüft aus. Mitglieder von `admin` und `wheel` erreichen
        // root ohnehin per sudo; eine andere Gruppe ist eine echte Ausweitung.
        let sandbox = try makeSandbox(fileMode: 0o775)
        defer { sandbox.remove() }

        let gid = (try? FileManager.default.attributesOfItem(atPath: sandbox.binary.path))
            .flatMap { ($0[.groupOwnerAccountID] as? NSNumber)?.uint32Value } ?? .max
        if WIMTool.isPrivilegedGroup(gid) {
            try WIMTool.validateToolPath(
                sandbox.binary.path, helperExecutable: helperSibling(of: sandbox)
            )
        } else {
            let error = try #require(throws: BiscuitError.self) {
                try WIMTool.validateToolPath(
                    sandbox.binary.path, helperExecutable: helperSibling(of: sandbox)
                )
            }
            #expect(error.diagnostics?.contains("group-writable") == true)
        }
    }

    @Test("admin und wheel gelten als bereits privilegiert")
    func privilegedGroupsRecognised() {
        // Namensbasiert, nicht nach fester GID: die Zahlen unterscheiden sich
        // zwischen Systemen.
        var adminFound = false
        var wheelFound = false
        for gid in UInt32(0)...UInt32(200) {
            guard let name = WIMTool.groupName(gid) else { continue }
            if name == "admin" { adminFound = true; #expect(WIMTool.isPrivilegedGroup(gid)) }
            if name == "wheel" { wheelFound = true; #expect(WIMTool.isPrivilegedGroup(gid)) }
        }
        #expect(adminFound && wheelFound, "admin/wheel auf diesem System nicht gefunden")
    }

    @Test("Das echte Homebrew-Verzeichnis wird nicht mehr abgelehnt")
    func realHomebrewIsAccepted() throws {
        // Genau der Fall aus dem Protokoll eines echten Laufs:
        // „rejected tool path /opt/homebrew/bin: writable by group or others
        // (mode 775)" — gefolgt davon, dass derselbe Pfad doch benutzt wurde.
        let path = "/opt/homebrew/bin/\(WIMTool.expectedToolName)"
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        try WIMTool.validateToolPath(path, helperExecutable: nil)
    }

    @Test("Ein nicht vorhandener Pfad wird abgelehnt")
    func rejectsMissingFile() throws {
        let error = try #require(throws: BiscuitError.self) {
            try WIMTool.validateToolPath(
                "/opt/homebrew/bin/\(WIMTool.expectedToolName)-does-not-exist",
                helperExecutable: nil
            )
        }
        #expect(error.diagnostics != nil)
    }

    // MARK: - Locating

    @Test("Ein abgelehnter Vorschlag macht den Auftrag nicht unmöglich")
    func rejectedPreferenceFallsBack() throws {
        // Refusing the whole job because the app offered a bad path would turn
        // a hardening check into a denial of service.
        let sandbox = try makeSandbox()
        defer { sandbox.remove() }

        var rejections: [BiscuitError] = []
        let tool = WIMTool.locateTrusted(
            // Outside every allowed directory.
            preferring: sandbox.binary.path,
            helperExecutable: nil,
            onRejection: { rejections.append($0) }
        )
        #expect(rejections.count == 1, "Ablehnung nicht gemeldet")
        // Whether a tool is found depends on the machine; what matters is that
        // the rejected path is not the one chosen.
        #expect(tool?.executablePath != sandbox.binary.path)
    }

    @Test("Ein gültiger Vorschlag wird bevorzugt")
    func validPreferenceIsUsed() throws {
        let sandbox = try makeSandbox()
        defer { sandbox.remove() }

        var rejections: [BiscuitError] = []
        let tool = WIMTool.locateTrusted(
            preferring: sandbox.binary.path,
            helperExecutable: helperSibling(of: sandbox),
            onRejection: { rejections.append($0) }
        )
        #expect(rejections.isEmpty)
        #expect(tool?.executablePath == sandbox.binary.path)
    }

    @Test("Ohne Vorschlag wird das Geschwister des Helfers gefunden")
    func findsSiblingWithoutPreference() throws {
        // No client input at all: this is the path the helper derives itself.
        let sandbox = try makeSandbox()
        defer { sandbox.remove() }

        let tool = WIMTool.locateTrusted(
            preferring: nil, helperExecutable: helperSibling(of: sandbox)
        )
        #expect(tool?.executablePath == sandbox.binary.path)
    }

    @Test("Die unsichere locate(preferring:) existiert nicht mehr")
    func unsafeLocateIsGone() throws {
        // Removed rather than deprecated, so it cannot be reached by accident.
        // Checked in the source because an absent function cannot be called
        // from a test to prove its absence.
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: String?
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent("Sources/BiscuitKit/Jobs/WIMTool.swift")
            if let data = try? Data(contentsOf: candidate) {
                source = String(decoding: data, as: UTF8.self)
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        let text = try #require(source, "WIMTool.swift nicht gefunden")
        #expect(!text.contains("func locate(preferring"))
    }
}

/// Confirms the helper uses the validating variant.
@Suite("Werkzeugpfad: Aufrufstelle im Helfer")
struct WIMToolCallSiteTests {
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

    @Test("Der Helfer nutzt locateTrusted")
    func helperUsesTrustedLocate() throws {
        let source = try #require(Self.helperSource, "Helferquelle nicht gefunden")
        #expect(source.contains("WIMTool.locateTrusted("))
        #expect(source.contains("helperExecutable:"))
    }

    @Test("Der Helfer gibt den Pfad nicht ungeprüft weiter")
    func helperDoesNotPassPathDirectly() throws {
        let source = try #require(Self.helperSource)
        #expect(
            !source.contains("WIMTool.locate(preferring:"),
            "ungeprüfter Werkzeugpfad ist zurück"
        )
    }
}

/// `version()` liefert eine Zeile, nicht den Lizenztext.
@Suite("wimlib-Versionsmeldung", .serialized)
struct WIMToolVersionTests {
    @Test("Die Version ist einzeilig", .timeLimit(.minutes(2)))
    func versionIsOneLine() async throws {
        // Im Diagnosebericht eines echten Laufs stand die vollständige
        // siebenzeilige Ausgabe von `wimlib-imagex --version` als *ein*
        // Protokolleintrag — samt Copyright, GPL-Hinweis,
        // Gewährleistungsausschluss und Forenadresse. Das verdrängt die Zeilen,
        // auf die es in einem Fehlerbericht ankommt.
        guard let tool = WIMTool.locateTrusted(preferring: nil, helperExecutable: nil) else {
            return
        }
        guard let version = await tool.version() else {
            Issue.record(Comment("wimlib meldet keine Version"))
            return
        }
        #expect(!version.contains("\n"), "mehrzeilig: \(version.prefix(80))")
        #expect(!version.lowercased().contains("copyright"))
        #expect(!version.lowercased().contains("warranty"))
        #expect(version.lowercased().contains("wimlib"))
    }
}
