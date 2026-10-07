import Foundation
import Testing
@testable import BiscuitKit

/// End-to-end: a compressed image written to a real block device.
///
/// The unit tests prove the decompressor produces the right bytes and the
/// writer handles block alignment. Neither proves the two work together, which
/// is where the interesting failures live — a rewind that does not rewind, a
/// capacity check against the compressed size, a progress bar fed the wrong
/// total.
@Suite("Komprimiert auf echtes Gerät", .serialized)
struct CompressedWriteIntegrationTests {
    private let writer = RawImageWriter()
    private static let payloadSize = 8 * 1024 * 1024

    private func makeCompressed(
        tool: String,
        arguments: [String],
        producing name: String
    ) throws -> (directory: URL, archive: URL, digest: String)? {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-cw-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let original = directory.appendingPathComponent("orig.img")
        try TestFixture.writeImageFile(at: original, sizeBytes: Self.payloadSize)
        let digest = try Checksum.hashFile(at: original)

        guard let executable = ProcessRunner.locate([
            "/usr/bin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"
        ]) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let archive = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: archive.path) else {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
        return (directory, archive, digest)
    }

    /// Reads back from the device and hashes, to compare against the original.
    private func deviceDigest(_ image: AttachedDiskImage, count: Int) throws -> String {
        var hasher = IncrementalHasher(algorithm: .sha256)
        var offset = 0
        let chunk = 1 << 20
        while offset < count {
            let size = min(chunk, count - offset)
            let data = try image.readDevice(offset: UInt64(offset), count: size)
            hasher.update(data)
            offset += size
        }
        return hasher.finalizeHex()
    }

    @Test("xz-Abbild landet bytegleich auf dem Gerät")
    func xzWritesCorrectly() async throws {
        guard let fixture = try makeCompressed(
            tool: "xz", arguments: ["-k", "-f", "-T0", "orig.img"], producing: "orig.img.xz"
        ) else {
            Issue.record(Comment("xz nicht gefunden — brew install xz"))
            return
        }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { device.detach() }

        let fd = try TestFixture.openDescriptor(fixture.archive)
        defer { close(fd) }

        let source = try ImageSourceFactory.make(fileDescriptor: fd)
        // xz records the expanded size exactly, so the capacity check is
        // conclusive rather than a guess.
        #expect(source.totalBytes == .exact(UInt64(Self.payloadSize)))

        let recorder = JobRecorder()
        let request = JobRequest.test(target: device.device)
        let written = try await writer.write(
            source: source,
            to: device.device,
            context: recorder.makeContext(request: request)
        )

        #expect(written == UInt64(Self.payloadSize))
        #expect(try deviceDigest(device, count: Self.payloadSize) == fixture.digest)
    }

    @Test("gzip-Abbild landet bytegleich auf dem Gerät")
    func gzipWritesCorrectly() async throws {
        guard let fixture = try makeCompressed(
            tool: "gzip", arguments: ["-k", "-f", "orig.img"], producing: "orig.img.gz"
        ) else { return }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { device.detach() }

        let fd = try TestFixture.openDescriptor(fixture.archive)
        defer { close(fd) }

        let source = try ImageSourceFactory.make(fileDescriptor: fd)
        let recorder = JobRecorder()
        let request = JobRequest.test(target: device.device)
        let written = try await writer.write(
            source: source,
            to: device.device,
            context: recorder.makeContext(request: request)
        )

        #expect(written == UInt64(Self.payloadSize))
        #expect(try deviceDigest(device, count: Self.payloadSize) == fixture.digest)

        // The approximate size must have produced a warning rather than silent
        // confidence.
        #expect(
            recorder.logs.contains { $0.level == .warning && $0.message.contains("approximate") },
            "unsichere Größe hätte eine Warnung erzeugen müssen"
        )
    }

    @Test("Verifikation funktioniert auch für komprimierte Quellen")
    func verificationRewindsCompressedSource() async throws {
        // Verification re-reads the source from the start. For a compressed
        // stream that means decompressing a second time, and a rewind that
        // silently does nothing would make verification compare the device
        // against an empty stream — and pass.
        guard let fixture = try makeCompressed(
            tool: "xz", arguments: ["-k", "-f", "-T0", "orig.img"], producing: "orig.img.xz"
        ) else { return }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { device.detach() }

        let fd = try TestFixture.openDescriptor(fixture.archive)
        defer { close(fd) }

        let source = try ImageSourceFactory.make(fileDescriptor: fd)
        let recorder = JobRecorder()
        let request = JobRequest.test(target: device.device, verify: true)
        let context = recorder.makeContext(request: request)

        let written = try await writer.write(source: source, to: device.device, context: context)
        try await writer.verify(
            source: source,
            against: device.device,
            bytesWritten: written,
            context: context
        )

        let compared = recorder.progress
            .filter { $0.phase == .verifying }
            .map(\.bytesProcessed)
            .max() ?? 0
        #expect(compared == written, "Verifikation hat nicht die volle Länge verglichen")
    }

    @Test("Verifikation erkennt Korruption auch bei komprimierter Quelle")
    func verificationDetectsCorruptionFromCompressed() async throws {
        guard let fixture = try makeCompressed(
            tool: "xz", arguments: ["-k", "-f", "-T0", "orig.img"], producing: "orig.img.xz"
        ) else { return }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { device.detach() }

        let fd = try TestFixture.openDescriptor(fixture.archive)
        defer { close(fd) }

        let source = try ImageSourceFactory.make(fileDescriptor: fd)
        let recorder = JobRecorder()
        let request = JobRequest.test(target: device.device, verify: true)
        let context = recorder.makeContext(request: request)

        let written = try await writer.write(source: source, to: device.device, context: context)
        try device.corruptByte(at: 3_000_000)

        var caught: BiscuitError?
        do {
            try await writer.verify(
                source: source, against: device.device,
                bytesWritten: written, context: context
            )
        } catch let error as BiscuitError {
            caught = error
        }
        #expect(caught?.kind == .verificationFailed)
    }

    @Test("Ein zu kleines Gerät wird anhand der entpackten Größe erkannt")
    func capacityCheckedAgainstExpandedSize() async throws {
        // The decisive case: 8 MiB expand from roughly 8 MiB of xz, so a check
        // against the *compressed* size would wrongly accept a 4 MiB device.
        guard let fixture = try makeCompressed(
            tool: "xz", arguments: ["-k", "-f", "-T0", "orig.img"], producing: "orig.img.xz"
        ) else { return }
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(4))
        defer { device.detach() }

        let fd = try TestFixture.openDescriptor(fixture.archive)
        defer { close(fd) }

        let source = try ImageSourceFactory.make(fileDescriptor: fd)
        let recorder = JobRecorder()
        let request = JobRequest.test(target: device.device)

        var caught: BiscuitError?
        do {
            _ = try await writer.write(
                source: source, to: device.device,
                context: recorder.makeContext(request: request)
            )
        } catch let error as BiscuitError {
            caught = error
        }
        let error = try #require(caught, "zu kleines Gerät hätte abgelehnt werden müssen")
        #expect(error.kind == .deviceTooSmall)

        // Nothing may have been written: the check happens before the first byte.
        let head = try device.readDevice(count: 4096)
        #expect(head.allSatisfy { $0 == 0 })
    }

    @Test("Kapazitätsbewertung unterscheidet sicher, unsicher und unbekannt")
    func capacityEvaluationIsHonest() {
        let capacity: UInt64 = .gibibytes(16)

        #expect(CapacityCheck.evaluate(expanded: .exact(.gibibytes(8)), deviceCapacity: capacity) == .fits)
        #expect(
            CapacityCheck.evaluate(expanded: .exact(.gibibytes(32)), deviceCapacity: capacity)
                == .tooSmall(required: .gibibytes(32), available: capacity)
        )
        // A figure already too large is decisive even when it is unreliable —
        // being wrong can only make it larger.
        #expect(
            CapacityCheck.evaluate(
                expanded: .approximate(.gibibytes(32), caveat: "x"), deviceCapacity: capacity
            ) == .tooSmall(required: .gibibytes(32), available: capacity)
        )
        // A figure that fits but is unreliable must not be reported as fitting.
        guard case .uncertain = CapacityCheck.evaluate(
            expanded: .approximate(.gibibytes(8), caveat: "gzip_isize_modulo"),
            deviceCapacity: capacity
        ) else {
            Issue.record("unsichere Größe wurde als sicher behandelt")
            return
        }
        #expect(CapacityCheck.evaluate(expanded: .unknown, deviceCapacity: capacity) == .unknown)
    }
}

/// The behaviour borrowed from Raspberry Pi Imager: on a checksum mismatch the
/// disk must end up obviously unusable rather than plausibly complete.
@Suite("Prüfsumme beim Schreiben", .serialized)
struct WriteDigestIntegrationTests {
    private let writer = RawImageWriter()

    @Test("Korrekte Prüfsumme: alles landet auf dem Gerät")
    func matchingDigestWritesEverything() async throws {
        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { device.detach() }

        let size = 6 * 1024 * 1024
        let url = try TestFixture.makeImageFile(sizeBytes: size)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = try Checksum.hashFile(at: url)

        let fd = try TestFixture.openDescriptor(url)
        defer { close(fd) }

        let recorder = JobRecorder()
        let written = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: device.device,
            context: recorder.makeContext(request: .test(target: device.device)),
            expectedDigest: digest
        )

        #expect(written == UInt64(size))
        // Including the first megabyte, which was written last.
        #expect(try device.readDevice(count: size) == (try Data(contentsOf: url)))
    }

    @Test("Falsche Prüfsumme: das erste Megabyte bleibt ungeschrieben")
    func mismatchLeavesDiskUnbootable() async throws {
        // The point of withholding the head: a disk written from a corrupted
        // image looks finished and fails later, on other hardware, in a way
        // nobody traces back to here. Without a partition table it is
        // unmistakably unusable.
        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { device.detach() }

        let size = 6 * 1024 * 1024
        let url = try TestFixture.makeImageFile(sizeBytes: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let fd = try TestFixture.openDescriptor(url)
        defer { close(fd) }

        let recorder = JobRecorder()
        var caught: BiscuitError?
        do {
            _ = try await writer.write(
                source: try DescriptorImageSource(fileDescriptor: fd),
                to: device.device,
                context: recorder.makeContext(request: .test(target: device.device)),
                expectedDigest: String(repeating: "f", count: 64)
            )
        } catch let error as BiscuitError {
            caught = error
        }

        let error = try #require(caught, "falsche Prüfsumme hätte auffallen müssen")
        #expect(error.kind == .checksumMismatch)

        // The decisive assertion: no boot sector, so no firmware will try.
        let head = try device.readDevice(count: 512)
        #expect(head.allSatisfy { $0 == 0 }, "der Bootsektor hätte leer bleiben müssen")

        // The remainder was written — that is fine and expected; what matters
        // is that the disk cannot be mistaken for a working one.
        let later = try device.readDevice(offset: 2 * 1024 * 1024, count: 4096)
        #expect(!later.allSatisfy { $0 == 0 }, "der Rest sollte geschrieben worden sein")
    }

    @Test("Ohne erwartete Prüfsumme wird nichts zurückgehalten")
    func noDigestWritesHeadImmediately() async throws {
        let device = try AttachedDiskImage.create(sizeBytes: .mebibytes(16))
        defer { device.detach() }

        let size = 2 * 1024 * 1024
        let url = try TestFixture.makeImageFile(sizeBytes: size)
        defer { try? FileManager.default.removeItem(at: url) }

        let fd = try TestFixture.openDescriptor(url)
        defer { close(fd) }

        let recorder = JobRecorder()
        _ = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: device.device,
            context: recorder.makeContext(request: .test(target: device.device))
        )
        #expect(try device.readDevice(count: size) == (try Data(contentsOf: url)))
    }
}
