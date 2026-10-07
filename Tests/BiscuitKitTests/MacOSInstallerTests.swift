import Foundation
import Testing
@testable import BiscuitKit

/// Parsing `softwareupdate --list-full-installers`.
///
/// Apple has changed this output before — the `Deferred` field is a later
/// addition — so the parser is driven by the field names rather than by
/// position, and these tests exist to keep it that way.
@Suite("macOS-Installationsprogramme")
struct MacOSInstallerCatalogueTests {
    private let realOutput = """
        Finding available software
        Software Update found the following full installers:
        * Title: macOS 27 Golden Gate, Version: 27.0.1, Size: 17955378KiB, Build: 26A434, Deferred: NO
        * Title: macOS 27 Golden Gate, Version: 27.0, Size: 17969056KiB, Build: 26A428, Deferred: NO
        * Title: macOS Tahoe, Version: 26.7.1, Size: 17950170KiB, Build: 25G241, Deferred: NO
        * Title: macOS Sequoia, Version: 15.8.1, Size: 15297386KiB, Build: 24H32, Deferred: NO
        """

    @Test("Echte Ausgabe wird vollständig geparst")
    func parsesRealOutput() {
        let installers = MacOSInstallerCatalogue.parse(realOutput)
        #expect(installers.count == 4)

        let newest = installers[0]
        #expect(newest.title == "macOS 27 Golden Gate")
        #expect(newest.version == "27.0.1")
        #expect(newest.build == "26A434")
        #expect(newest.sizeBytes == 17_955_378 * 1024)
        #expect(!newest.isDeferred)
    }

    @Test("Die Ausgabe dieses Macs lässt sich parsen")
    func parsesFixtureFromThisMachine() throws {
        // Captured from a real run. If Apple changes the format, this is where
        // it shows up — before a user discovers an empty list.
        guard let url = Bundle.module.url(
            forResource: "softwareupdate-list", withExtension: "txt", subdirectory: "Fixtures"
        ) else {
            Issue.record(Comment("Fixture fehlt"))
            return
        }
        let installers = MacOSInstallerCatalogue.parse(
            String(decoding: try Data(contentsOf: url), as: UTF8.self)
        )
        #expect(!installers.isEmpty, "keine Installationsprogramme erkannt")
        for installer in installers {
            #expect(!installer.version.isEmpty)
            #expect(!installer.build.isEmpty)
            #expect(installer.sizeBytes > 1_000_000_000, "unplausible Größe für \(installer.version)")
        }
    }

    @Test("Versionen werden numerisch sortiert, nicht alphabetisch")
    func sortsNumerically() {
        // "26.10" above "26.9" is the case a string comparison gets wrong, and
        // the one that puts an old installer at the top of the list.
        let output = """
            * Title: macOS A, Version: 26.9, Size: 100KiB, Build: B1, Deferred: NO
            * Title: macOS B, Version: 26.10, Size: 100KiB, Build: B2, Deferred: NO
            * Title: macOS C, Version: 26.10.1, Size: 100KiB, Build: B3, Deferred: NO
            """
        let versions = MacOSInstallerCatalogue.parse(output).map(\.version)
        #expect(versions == ["26.10.1", "26.10", "26.9"])
    }

    @Test("Ein fehlendes Deferred-Feld gilt als nicht zurückgestellt")
    func missingDeferredField() {
        // Older macOS releases omit the field entirely. Treating absence as
        // "deferred" would hide every installer on those systems.
        let output = "* Title: macOS Big Sur, Version: 11.7.10, Size: 12000000KiB, Build: 20G1427"
        let installers = MacOSInstallerCatalogue.parse(output)
        #expect(installers.count == 1)
        #expect(installers[0].isDeferred == false)
        #expect(installers[0].build == "20G1427")
    }

    @Test("Zurückgestellte Einträge werden als solche erkannt")
    func deferredIsDetected() {
        let output = "* Title: macOS X, Version: 26.1, Size: 100KiB, Build: B, Deferred: YES"
        #expect(MacOSInstallerCatalogue.parse(output).first?.isDeferred == true)
    }

    @Test("Ein Titel mit Komma zerstört das Parsing nicht")
    func titleWithComma() {
        // The split is driven by the known field names rather than by the
        // comma, precisely so a marketing name can contain one.
        let output = "* Title: macOS Foo, Bar Edition, Version: 30.0, Size: 100KiB, Build: Z1, Deferred: NO"
        let installer = MacOSInstallerCatalogue.parse(output).first
        #expect(installer?.title == "macOS Foo, Bar Edition")
        #expect(installer?.version == "30.0")
    }

    @Test("Unbrauchbare Zeilen werden übersprungen, nicht geraten")
    func ignoresNoise() {
        let output = """
            Finding available software
            Software Update found the following full installers:
            * Something entirely different
            * Title: macOS Real, Version: 27.0, Size: 100KiB, Build: R1, Deferred: NO
            Warning: some unrelated message
            """
        let installers = MacOSInstallerCatalogue.parse(output)
        #expect(installers.count == 1)
        #expect(installers[0].version == "27.0")
    }

    @Test("Leere Ausgabe ergibt eine leere Liste")
    func emptyOutput() {
        #expect(MacOSInstallerCatalogue.parse("").isEmpty)
        #expect(MacOSInstallerCatalogue.parse("Finding available software\n").isEmpty)
    }

    @Test("Größenangaben werden korrekt umgerechnet")
    func sizeParsing() {
        #expect(MacOSInstallerCatalogue.parseSize("17955378KiB") == 17_955_378 * 1024)
        #expect(MacOSInstallerCatalogue.parseSize("1024KiB") == 1_048_576)
        #expect(MacOSInstallerCatalogue.parseSize("5MiB") == 5 * 1024 * 1024)
        #expect(MacOSInstallerCatalogue.parseSize("100") == 100)
        #expect(MacOSInstallerCatalogue.parseSize("abc") == nil)
    }

    @Test("Der erwartete Ablageort folgt dem Titel")
    func installerLocation() {
        // `softwareupdate` names the bundle after the marketing title.
        let installer = MacOSInstaller(
            title: "macOS Sequoia", version: "15.8", build: "24H23",
            sizeBytes: 0, isDeferred: false
        )
        #expect(
            MacOSInstallerCatalogue.expectedInstallerLocation(for: installer).path
                == "/Applications/Install macOS Sequoia.app"
        )
    }

    @Test("Hauptversion wird aus der Versionsnummer abgeleitet")
    func majorVersion() {
        let installer = MacOSInstaller(
            title: "x", version: "26.7.1", build: "b", sizeBytes: 0, isDeferred: false
        )
        #expect(installer.majorVersion == 26)
    }
}

/// Exercises the live tool. Needs no privileges and no download.
@Suite("softwareupdate live", .serialized)
struct MacOSInstallerLiveTests {
    @Test("Die Liste lässt sich tatsächlich abrufen", .timeLimit(.minutes(3)))
    func listsInstallers() async throws {
        // The one check a fixture cannot make: that the tool is still at the
        // expected path, still exits zero, and still writes to stdout.
        guard FileManager.default.isExecutableFile(atPath: MacOSInstallerCatalogue.tool) else {
            Issue.record(Comment("softwareupdate nicht gefunden"))
            return
        }

        let catalogue = MacOSInstallerCatalogue()
        let installers: [MacOSInstaller]
        do {
            installers = try await catalogue.list()
        } catch let error as BiscuitError {
            // A machine without a network connection is a legitimate state for
            // a test run, and not a failure of this code.
            Issue.record(Comment("Liste nicht abrufbar: \(error.message)"))
            return
        }

        #expect(!installers.isEmpty)
        #expect(installers.allSatisfy { $0.sizeBytes > 1_000_000_000 })
        // Sorted newest first.
        for pair in zip(installers, installers.dropFirst()) {
            let ordering = MacOSInstallerCatalogue.compareVersions(pair.0.version, pair.1.version)
            #expect(ordering != .orderedAscending, "Reihenfolge verletzt")
        }
    }
}
