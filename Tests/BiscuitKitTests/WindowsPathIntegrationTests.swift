import Foundation
import Testing
@testable import BiscuitKit

/// Integration tests for the Windows media path: the file-tree copy and the WIM
/// split that together replace a raw write.
///
/// The split is the part most likely to break silently. If `wimlib-imagex`
/// changes its output naming or its progress format, the stick still looks
/// finished and Windows Setup then cannot find its install image.
@Suite("Windows-Pfad", .serialized)
struct WindowsPathIntegrationTests {
    // No preferred path: this is the resolution the helper performs on its
    // own, without anything from the client.
    private static let wimlib: WIMTool? = WIMTool.locateTrusted(
        preferring: nil, helperExecutable: nil
    )

    // MARK: - File tree copy

    @Test("Plan erfasst alle Dateien und summiert korrekt")
    func copyPlanCountsEverything() throws {
        let tree = try TestFixture.makeTree(files: [
            ("bootmgr", 4096),
            ("EFI/BOOT/BOOTX64.EFI", 8192),
            ("sources/boot.wim", 65536),
            ("sources/install.wim", 131072),
            ("setup.exe", 2048)
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let copier = FileTreeCopier()
        let plan = try copier.plan(source: tree) { _, _ in false }

        #expect(plan.files.count == 5)
        #expect(plan.skipped.isEmpty)
        #expect(plan.totalBytes == 4096 + 8192 + 65536 + 131072 + 2048)
        // Directories must be planned too, or the copy fails on the first
        // nested file.
        #expect(plan.directories.contains("EFI"))
        #expect(plan.directories.contains("EFI/BOOT"))
        #expect(plan.directories.contains("sources"))
    }

    @Test("Übergroße Dateien werden zurückgehalten, nicht kopiert")
    func copyPlanSkipsOversizedFiles() throws {
        let tree = try TestFixture.makeTree(files: [
            ("bootmgr", 4096),
            ("sources/install.wim", 200_000),
            ("sources/boot.wim", 1024)
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let copier = FileTreeCopier()
        // Mirrors the real predicate: anything above the FAT32 ceiling is held
        // back for the split step.
        let plan = try copier.plan(source: tree) { _, size in size > 100_000 }

        #expect(plan.files.count == 2)
        #expect(plan.skipped.count == 1)
        #expect(plan.skipped.first?.relativePath == "sources/install.wim")
        // The skipped file must not be counted in the copy total, otherwise the
        // progress bar stalls at the end.
        #expect(plan.totalBytes == 4096 + 1024)
        #expect(plan.skipped.first?.isSplittableWIM == true)
    }

    @Test("Kopie reproduziert den Baum bytegleich")
    func copyReproducesTree() throws {
        let tree = try TestFixture.makeTree(files: [
            ("bootmgr", 4096),
            ("EFI/BOOT/BOOTX64.EFI", 8192),
            ("sources/boot.wim", 300_000),
            ("deep/nested/path/file.dat", 1234)
        ])
        defer { try? FileManager.default.removeItem(at: tree) }

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-dst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let copier = FileTreeCopier()
        let plan = try copier.plan(source: tree) { _, _ in false }

        let recorder = JobRecorder()
        let request = JobRequest.test(
            strategy: .windowsFAT32,
            target: Self.dummyDevice
        )
        try copier.execute(
            plan: plan,
            destination: destination,
            context: recorder.makeContext(request: request)
        )

        for file in plan.files {
            let original = try Data(contentsOf: file.source)
            let copied = try Data(
                contentsOf: destination.appendingPathComponent(file.relativePath)
            )
            #expect(copied == original, "Abweichung bei \(file.relativePath)")
        }

        // Progress must finish at the planned total, not short of it.
        let copyProgress = recorder.progress.filter { $0.phase == .copying }
        #expect(copyProgress.last?.bytesProcessed == plan.totalBytes)
    }

    @Test("Abbruch stoppt die Kopie mitten im Baum")
    func copyRespectsCancellation() throws {
        let tree = try TestFixture.makeTree(
            files: (0..<40).map { ("file\($0).bin", 256 * 1024) }
        )
        defer { try? FileManager.default.removeItem(at: tree) }

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-dst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let copier = FileTreeCopier()
        let plan = try copier.plan(source: tree) { _, _ in false }

        let cancellation = CancellationFlag()
        cancellation.set()

        let recorder = JobRecorder()
        let request = JobRequest.test(strategy: .windowsFAT32, target: Self.dummyDevice)

        #expect(throws: BiscuitError.self) {
            try copier.execute(
                plan: plan,
                destination: destination,
                context: recorder.makeContext(request: request, cancellation: cancellation)
            )
        }
    }

    @Test("Fortschritt wird in das vorgegebene Teilintervall skaliert")
    func copyProgressRespectsFractionRange() throws {
        let tree = try TestFixture.makeTree(
            files: (0..<12).map { ("f\($0).bin", 128 * 1024) }
        )
        defer { try? FileManager.default.removeItem(at: tree) }

        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-dst-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        let copier = FileTreeCopier()
        let plan = try copier.plan(source: tree) { _, _ in false }
        let recorder = JobRecorder()
        let request = JobRequest.test(strategy: .windowsFAT32, target: Self.dummyDevice)

        // The real caller reserves the tail of the copy phase for the WIM split,
        // so the bar must stay inside 0…0.65 here.
        try copier.execute(
            plan: plan,
            destination: destination,
            context: recorder.makeContext(request: request),
            phase: .copying,
            fractionRange: 0...0.65
        )

        let fractions = recorder.progress
            .filter { $0.phase == .copying }
            .compactMap(\.phaseFraction)
        #expect(!fractions.isEmpty)
        #expect(fractions.allSatisfy { $0 <= 0.65 + 0.0001 })
        #expect(fractions.last.map { $0 > 0.6 } == true)
    }

    // MARK: - WIM split

    @Test("install.wim wird in .swm-Teile unter der Grenze zerlegt")
    func wimSplitProducesParts() async throws {
        guard let tool = Self.wimlib else {
            Issue.record(Comment("wimlib nicht gefunden — brew install wimlib"))
            return
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-wim-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Build a real WIM with incompressible content so the parts have
        // predictable sizes.
        let captureRoot = scratch.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        for index in 0..<3 {
            try TestFixture.writeImageFile(
                at: captureRoot.appendingPathComponent("blob\(index).bin"),
                sizeBytes: 6 * 1024 * 1024,
                seed: UInt64(0xABCD + index)
            )
        }

        let wimURL = scratch.appendingPathComponent("install.wim")
        let capture = try await ProcessRunner.run(
            tool.executablePath,
            arguments: [
                "capture", captureRoot.path, wimURL.path,
                "--compress=none", "--no-acls"
            ],
            timeout: 300
        )
        try #require(capture.succeeded, "wim capture: \(capture.combinedOutput)")

        let originalSize = try RawImageWriter.fileSize(of: wimURL)
        #expect(originalSize > 16 * 1024 * 1024)

        // Split into ~8 MiB parts, mirroring what the real code does with
        // 3800 MiB against a 4 GiB ceiling.
        let destination = scratch.appendingPathComponent("install.swm")
        let recorder = JobRecorder()
        let request = JobRequest.test(strategy: .windowsFAT32, target: Self.dummyDevice)

        try await tool.split(
            source: wimURL,
            destination: destination,
            context: recorder.makeContext(request: request),
            partSizeMegabytes: 8
        )

        // wimlib names the parts install.swm, install2.swm, install3.swm — the
        // exact pattern Windows Setup looks for.
        let produced = try FileManager.default
            .contentsOfDirectory(atPath: scratch.path)
            .filter { $0.lowercased().hasSuffix(".swm") }
            .sorted()
        #expect(produced.count >= 3, "erwartete mehrere Teile, erhielt \(produced)")
        #expect(produced.contains("install.swm"))
        #expect(produced.contains("install2.swm"))

        // No part may exceed the limit, or the whole exercise was pointless.
        let limit: UInt64 = 9 * 1024 * 1024
        for name in produced {
            let size = try RawImageWriter.fileSize(
                of: scratch.appendingPathComponent(name)
            )
            #expect(size <= limit, "\(name) ist \(ByteCount.format(size)) groß")
        }

        // The split must be reversible, which is the real proof that the parts
        // form a valid set rather than just plausible files.
        let rejoined = scratch.appendingPathComponent("rejoined.wim")
        let join = try await ProcessRunner.run(
            tool.executablePath,
            arguments: ["join", rejoined.path]
                + produced.map { scratch.appendingPathComponent($0).path },
            timeout: 300
        )
        #expect(join.succeeded, "wim join: \(join.combinedOutput)")

        let verify = try await ProcessRunner.run(
            tool.executablePath,
            arguments: ["verify", rejoined.path],
            timeout: 300
        )
        #expect(verify.succeeded, "wim verify: \(verify.combinedOutput)")
    }

    @Test("Fortschritt des Zerlegens wird gemeldet")
    func wimSplitReportsProgress() async throws {
        guard let tool = Self.wimlib else {
            Issue.record(Comment("wimlib nicht gefunden — brew install wimlib"))
            return
        }

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-wimp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let captureRoot = scratch.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: captureRoot, withIntermediateDirectories: true)
        try TestFixture.writeImageFile(
            at: captureRoot.appendingPathComponent("blob.bin"),
            sizeBytes: 12 * 1024 * 1024
        )

        // LZX rather than no compression: it takes long enough that the throttle
        // cannot collapse the whole operation into its forced first and last
        // report, so intermediate values are observable without depending on
        // machine speed.
        let wimURL = scratch.appendingPathComponent("install.wim")
        let capture = try await ProcessRunner.run(
            tool.executablePath,
            arguments: ["capture", captureRoot.path, wimURL.path, "--compress=LZX", "--no-acls"],
            timeout: 600
        )
        try #require(capture.succeeded, "wim capture: \(capture.combinedOutput)")

        let recorder = JobRecorder()
        let request = JobRequest.test(strategy: .windowsFAT32, target: Self.dummyDevice)
        try await tool.split(
            source: wimURL,
            destination: scratch.appendingPathComponent("install.swm"),
            context: recorder.makeContext(request: request),
            partSizeMegabytes: 4
        )

        let splitProgress = recorder.progress.filter { $0.phase == .splittingWIM }
        #expect(!splitProgress.isEmpty, "keine Fortschrittsmeldung für das Zerlegen")

        // The decisive assertion: output from the real tool must have reached the
        // parser. wimlib writes its progress to *stderr* and nothing to stdout,
        // so a runner that watches only stdout reports no progress at all — the
        // bar would then sit frozen for the ten minutes a real install.wim takes.
        let details = splitProgress.compactMap(\.detail)
        #expect(
            details.contains { ProgressTextParser.percentage(in: $0) != nil },
            "keine auswertbare Tool-Ausgabe erreicht den Parser: \(details)"
        )

        // Fractions must stay ordered and within bounds.
        let fractions = splitProgress.compactMap(\.phaseFraction)
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
        for pair in zip(fractions, fractions.dropFirst()) {
            #expect(pair.0 <= pair.1, "Fortschritt lief zurück: \(pair.0) → \(pair.1)")
        }
    }

    @Test("wimlib wird gefunden, Version ist abfragbar")
    func wimlibDiscovery() async throws {
        guard let tool = Self.wimlib else {
            Issue.record(Comment("wimlib nicht gefunden — brew install wimlib"))
            return
        }
        let version = await tool.version()
        let text = try #require(version)
        #expect(text.lowercased().contains("wimlib"))

        // A path outside the allow-list is never used, however plausible it
        // looks. It names the executable of a root process, so it is checked
        // rather than preferred — see WIMToolPathTests.
        let outside = "/tmp/definitely-not-there-\(UUID().uuidString)"
        var rejected = 0
        let resolved = WIMTool.locateTrusted(
            preferring: outside, helperExecutable: nil, onRejection: { _ in rejected += 1 }
        )
        #expect(resolved?.executablePath != outside)
        #expect(rejected == 1, "Ablehnung nicht gemeldet")
    }

    // MARK: -

    private static let dummyDevice = StorageDevice(
        bsdName: "disk99",
        model: "Test",
        vendor: nil,
        sizeBytes: .gibibytes(16),
        blockSize: 512,
        bus: .usb,
        isRemovableMedia: true,
        isEjectable: true,
        isWritable: true,
        isSystemDisk: false,
        volumes: []
    )
}
