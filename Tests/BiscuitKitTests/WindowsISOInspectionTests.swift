import Foundation
import Testing
@testable import BiscuitKit

/// Runs a real Windows-shaped ISO through the real inspector.
///
/// The parser has its own unit tests, but those prove nothing about the wiring:
/// the WIM has to be read *while the image is still mounted*, because the mount
/// point is gone by the time the scan result is returned. That constraint is
/// invisible to a unit test and would show up as `nil` metadata on every real
/// ISO. So this builds an ISO with `hdiutil`, mounts it through the normal
/// path, and checks the metadata arrives.
@Suite("Windows-ISO-Erkennung", .serialized)
struct WindowsISOInspectionTests {
    /// Assembles an ISO that looks enough like Windows media to be detected:
    /// `sources/install.wim`, plus the boot files the detector requires.
    /// Returns the ISO and the scratch directory to remove afterwards.
    ///
    /// The directory is handed back rather than a cleanup closure: `FileManager`
    /// is not `Sendable`, so capturing it in one is rejected under strict
    /// concurrency.
    private static func makeISO(
        wimFixture: String,
        volumeName: String,
        fixtureExtension: String = "wim",
        innerName: String = "install.wim"
    ) throws -> (iso: URL, scratch: URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-iso-\(UUID().uuidString.prefix(8))")
        let payload = root.appendingPathComponent("root")
        let fm = FileManager.default
        try fm.createDirectory(
            at: payload.appendingPathComponent("sources"), withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: payload.appendingPathComponent("efi/boot"), withIntermediateDirectories: true
        )

        guard let wim = Bundle.module.url(
            forResource: wimFixture, withExtension: fixtureExtension, subdirectory: "Fixtures"
        ) else {
            throw BiscuitError(kind: .sourceUnreadable, message: "fixture \(wimFixture) missing")
        }
        try fm.copyItem(at: wim, to: payload.appendingPathComponent("sources/\(innerName)"))
        try Data("BOOTMGR".utf8).write(to: payload.appendingPathComponent("bootmgr"))
        try Data("EFI".utf8).write(to: payload.appendingPathComponent("efi/boot/bootx64.efi"))

        let iso = root.appendingPathComponent("image.iso")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid", "-iso", "-joliet",
            "-default-volume-name", volumeName,
            "-o", iso.path, payload.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: "hdiutil makehybrid failed with \(process.terminationStatus)"
            )
        }
        return (iso, root)
    }

    @Test("Ein x64-Windows-ISO wird mit Editionen und Version erkannt", .timeLimit(.minutes(3)))
    func inspectsX64ISO() async throws {
        let (iso, scratch) = try Self.makeISO(wimFixture: "windows11-x64", volumeName: "WIN11_X64")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try await ISOInspector().inspect(iso)

        #expect(source.payload == .windowsInstaller)
        #expect(source.supportedStrategies == [.windowsFAT32])

        // The whole point: metadata survived the mount scope.
        let metadata = try #require(
            source.windowsMetadata,
            "keine WIM-Metadaten — vermutlich außerhalb der Mount-Klammer gelesen"
        )
        #expect(metadata.imageCount == 2)
        #expect(metadata.commonArchitecture == .x64)
        #expect(metadata.commonVersion?.build == 26_100)
        #expect(metadata.images.map(\.name) == ["Windows 11 Home", "Windows 11 Pro"])
        #expect(metadata.allLanguages == ["de-DE", "en-US"])

        // And reached the notes the user actually sees.
        let notes = source.detectionNotes.joined(separator: " | ")
        #expect(notes.contains("26100"), "Version fehlt in den Hinweisen: \(notes)")
        #expect(notes.contains("x64"), "Architektur fehlt in den Hinweisen")
        #expect(notes.contains("Windows 11 Pro"), "Editionen fehlen in den Hinweisen")
    }

    @Test("Ein ARM64-ISO wird ausdrücklich als untauglich für normale PCs gemeldet",
          .timeLimit(.minutes(3)))
    func warnsAboutARM64() async throws {
        // Without this the user gets a stick that looks finished and does not
        // boot, with nothing anywhere to explain why.
        let (iso, scratch) = try Self.makeISO(
            wimFixture: "windows11-arm64", volumeName: "WIN11_ARM"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try await ISOInspector().inspect(iso)
        let metadata = try #require(source.windowsMetadata)
        #expect(metadata.commonArchitecture == .arm64)
        #expect(metadata.commonArchitecture?.isCommonPCArchitecture == false)

        let notes = source.detectionNotes.joined(separator: " | ")
        #expect(notes.contains("ARM64"), "ARM64 wird nicht benannt: \(notes)")
        // The warning text, not merely the architecture line.
        #expect(
            notes.contains(t(.noteWindowsArchitectureUnusual, "ARM64")),
            "keine Warnung zur Architektur"
        )
    }

    @Test("Ein Teil eines geteilten Satzes wird als unvollständig gemeldet",
          .timeLimit(.minutes(3)))
    func warnsAboutSplitSet() async throws {
        let (iso, scratch) = try Self.makeISO(wimFixture: "split-part2", volumeName: "WIN_SPLIT")
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try await ISOInspector().inspect(iso)
        let metadata = try #require(source.windowsMetadata)
        #expect(metadata.isSplit)
        #expect(
            source.detectionNotes.contains(t(.noteWindowsSplitSet, 2, 3)),
            "geteilter Satz nicht gemeldet: \(source.detectionNotes)"
        )
    }

    @Test("Unlesbare Metadaten brechen die Erkennung nicht ab", .timeLimit(.minutes(3)))
    func corruptMetadataDoesNotAbortInspection() async throws {
        // A medium can still be built without knowing the edition list, so a
        // metadata failure must degrade rather than reject the ISO.
        let (iso, scratch) = try Self.makeISO(
            wimFixture: "corrupt-xmlsize", volumeName: "WIN_BAD"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try await ISOInspector().inspect(iso)
        #expect(source.payload == .windowsInstaller, "ISO wurde wegen der Metadaten verworfen")
        #expect(source.supportedStrategies == [.windowsFAT32])
        #expect(source.windowsMetadata == nil)
        // The note has to be the one the cap produces. Accepting any note here
        // would let a different failure pass as this one.
        #expect(
            source.detectionNotes.contains(t(.errorWimMetadataUnreadable)),
            "Fehlschlag nicht als unlesbar gemeldet: \(source.detectionNotes)"
        )
    }
}

extension WindowsISOInspectionTests {
    /// A solid-compressed `install.wim` must still be inspected correctly.
    ///
    /// Real ESDs and UUP-built ISOs are solid-compressed, so this is the shape
    /// the reader is most likely to meet outside a test.
    @Test("Ein solid-komprimiertes Abbild wird gelesen und als solid erkannt",
          .timeLimit(.minutes(3)))
    func inspectsSolidImage() async throws {
        let (iso, scratch) = try Self.makeISO(
            wimFixture: "solid-windows", volumeName: "WIN_SOLID"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try await ISOInspector().inspect(iso)
        #expect(source.payload == .windowsInstaller)

        let metadata = try #require(source.windowsMetadata)
        #expect(metadata.compression == .lzms)
        #expect(metadata.hasSolidResources == true)
        #expect(metadata.canBeSplit == false, "solid wäre zum Teilen geschickt worden")
        // Metadata is still readable despite the compression: the XML blob is
        // stored uncompressed in every variant wimlib produces.
        #expect(metadata.images.first?.editionID == "Professional")
        #expect(metadata.commonArchitecture == .x64)
    }
}

extension WindowsISOInspectionTests {
    /// An ISO carrying `sources/install.esd` rather than `install.wim`.
    ///
    /// This is the shape Microsoft's consumer download produces. The detector
    /// has always recognised `install.esd`, but nothing had ever run a real
    /// ESD-shaped ISO through the whole mount-and-read path.
    @Test("Ein ISO mit install.esd wird vollständig gelesen", .timeLimit(.minutes(3)))
    func inspectsESDBasedISO() async throws {
        let (iso, scratch) = try Self.makeISO(
            wimFixture: "windows-esd",
            volumeName: "WIN_ESD",
            fixtureExtension: "esd",
            innerName: "install.esd"
        )
        defer { try? FileManager.default.removeItem(at: scratch) }

        let source = try await ISOInspector().inspect(iso)
        #expect(source.payload == .windowsInstaller)
        #expect(source.supportedStrategies == [.windowsFAT32])

        let metadata = try #require(
            source.windowsMetadata,
            "keine Metadaten aus install.esd — der Leser wurde nicht aufgerufen"
        )
        #expect(metadata.compression == .lzms)
        #expect(metadata.canBeSplit == false)
        #expect(metadata.images.count == 2)
        #expect(metadata.commonArchitecture == .x64)

        let notes = source.detectionNotes.joined(separator: " | ")
        #expect(notes.contains("26100"), Comment(rawValue: "Version fehlt: \(notes)"))
        #expect(notes.contains("Windows 11 Pro"), Comment(rawValue: "Editionen fehlen: \(notes)"))
    }
}
