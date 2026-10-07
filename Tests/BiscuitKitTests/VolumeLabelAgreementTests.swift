import Foundation
import Testing
@testable import BiscuitKit

/// Holds the label limits against the tool that enforces them.
///
/// `VolumeLabel.maximumLength` claimed 15 for exFAT. The real limit is 11, and
/// nothing noticed because every existing test exercised the *sanitiser*
/// against those same numbers — a closed loop. The numbers themselves had never
/// been compared with `diskutil`.
///
/// It surfaced on a real USB stick: the volume label of a Windows ISO,
/// truncated to the believed limit of 15, produced
///
///     CCCOMA_X64FRE_D does not appear to be a valid volume name
///     for its file system
///
/// from `diskutil eraseDisk` — *after* the partition signatures had already
/// been overwritten. A wrong constant turned into a half-erased stick.
///
/// These tests format a throwaway disk image rather than reason about specs, so
/// a future macOS that changes a limit is reported instead of guessed at.
@Suite("Datenträgernamen gegen diskutil", .serialized)
struct VolumeLabelAgreementTests {
    /// A detached disk image with one partition to format repeatedly.
    private struct Scratch {
        let image: URL
        let device: String

        func remove() {
            _ = try? Process.run(
                URL(fileURLWithPath: "/usr/bin/hdiutil"),
                arguments: ["detach", device, "-quiet"]
            )
            try? FileManager.default.removeItem(at: image)
        }
    }

    private func makeScratch() async -> Scratch? {
        let image = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-label-\(UUID().uuidString.prefix(8)).dmg")

        let create = try? await ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: [
                "create", "-size", "128m", "-layout", "GPTSPUD",
                "-type", "UDIF", "-fs", "ExFAT", "-volname", "SCRATCH", image.path
            ],
            timeout: 120
        )
        guard create?.succeeded == true else { return nil }

        let attach = try? await ProcessRunner.run(
            "/usr/bin/hdiutil",
            arguments: ["attach", "-nomount", image.path],
            timeout: 60
        )
        guard let output = attach?.standardOutput,
              let device = output.split(separator: "\n").first?
                  .split(separator: " ").first.map(String.init)
        else {
            try? FileManager.default.removeItem(at: image)
            return nil
        }
        return Scratch(image: image, device: device)
    }

    /// Whether `diskutil` accepts a label of this length for this filesystem.
    private func accepts(
        length: Int,
        filesystem: TargetFilesystem,
        on partition: String
    ) async -> Bool? {
        let label = String(repeating: "A", count: length)
        let result = try? await ProcessRunner.run(
            DeviceInspector.diskutil,
            arguments: ["eraseVolume", filesystem.diskutilValue, label, partition],
            timeout: 180
        )
        guard let result else { return nil }
        if result.succeeded { return true }
        // Only the name complaint counts as a rejection of the length; any
        // other failure means the probe itself did not work and must not be
        // read as evidence.
        if result.combinedOutput.contains("valid volume name") { return false }
        return nil
    }

    @Test("Die Grenzwerte stimmen mit diskutil überein", .timeLimit(.minutes(10)))
    func limitsMatchDiskutil() async throws {
        guard FileManager.default.isExecutableFile(atPath: DeviceInspector.diskutil),
              let scratch = await makeScratch()
        else {
            Issue.record(Comment("Wegwerf-Abbild nicht erstellbar — Prüfung übersprungen"))
            return
        }
        defer { scratch.remove() }
        let partition = "\(scratch.device)s1"

        // Only the two short-limit filesystems are probed. HFS+ and APFS allow
        // far more than Biscuit's 127, so the conservative value needs no
        // measurement — and formatting those takes long enough to make the
        // suite tiresome.
        for filesystem in [TargetFilesystem.exfat, .fat32] {
            let limit = VolumeLabel.maximumLength(for: filesystem)

            let atLimit = await accepts(
                length: limit, filesystem: filesystem, on: partition
            )
            #expect(
                atLimit != false,
                Comment(rawValue: "\(filesystem.rawValue): \(limit) Zeichen abgelehnt — Grenze zu hoch")
            )

            let aboveLimit = await accepts(
                length: limit + 1, filesystem: filesystem, on: partition
            )
            #expect(
                aboveLimit != true,
                Comment(rawValue: "\(filesystem.rawValue): \(limit + 1) Zeichen angenommen — Grenze zu niedrig")
            )
        }
    }

    @Test("Ein echtes Windows-ISO-Etikett übersteht die Bereinigung")
    func realWindowsLabelSurvives() {
        // Exactly the label that failed on hardware.
        let raw = "CCCOMA_X64FRE_DE-DE_DV9"
        for filesystem in [TargetFilesystem.exfat, .fat32] {
            let label = VolumeLabel.sanitise(raw, filesystem: filesystem)
            #expect(
                label.count <= VolumeLabel.maximumLength(for: filesystem),
                Comment(rawValue: "\(filesystem.rawValue): \(label) ist zu lang")
            )
            #expect(!label.isEmpty)
            // The hyphen is not in the permitted set, so it must be gone rather
            // than passed through to `diskutil`.
            #expect(!label.contains("-"))
        }
    }
}
