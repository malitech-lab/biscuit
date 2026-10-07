import Foundation
import Testing
@testable import BiscuitKit

/// Integration tests for the raw write path against a real block device.
///
/// Serialised: each test attaches and detaches a device node, and running them
/// concurrently makes failures hard to attribute.
@Suite("Rohschreiben gegen ein echtes Blockgerät", .serialized)
struct RawWriteIntegrationTests {
    private let writer = RawImageWriter()

    @Test("Abbild landet Byte für Byte auf dem Gerät")
    func writesExactBytes() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(64))
        defer { image.detach() }

        let sourceSize = 12 * 1024 * 1024
        let sourceURL = try TestFixture.makeImageFile(sizeBytes: sourceSize)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device)
        let context = recorder.makeContext(request: request)

        let written = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: image.device,
            context: context
        )

        #expect(written == UInt64(sourceSize))

        // The device must contain exactly the source bytes.
        let expected = try Data(contentsOf: sourceURL)
        let actual = try image.readDevice(count: sourceSize)
        #expect(actual == expected)
    }

    @Test("Letzter Teilblock wird mit Nullen aufgefüllt, nicht abgeschnitten")
    func padsFinalPartialBlock() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(16))
        defer { image.detach() }

        // Deliberately not a multiple of 512: the raw device rejects an unaligned
        // length, so the writer must pad. A truncating implementation would lose
        // the tail — which on a real ISO is where the GPT backup header lives.
        let sourceSize = 1_000_003
        let sourceURL = try TestFixture.makeImageFile(sizeBytes: sourceSize)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device)
        let written = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: image.device,
            context: recorder.makeContext(request: request)
        )

        // The reported byte count is the logical size, not the padded one.
        #expect(written == UInt64(sourceSize))

        let expected = try Data(contentsOf: sourceURL)
        let actual = try image.readDevice(count: sourceSize)
        #expect(actual == expected)

        // The padding itself must be zeros, not leftover buffer contents — a
        // classic information leak in hand-rolled writers.
        let tail = try image.readDevice(offset: UInt64(sourceSize), count: 509)
        #expect(tail.allSatisfy { $0 == 0 })
    }

    @Test("Verifikation bestätigt ein korrekt geschriebenes Gerät")
    func verifyAcceptsGoodWrite() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { image.detach() }

        let sourceSize = 6 * 1024 * 1024 + 777
        let sourceURL = try TestFixture.makeImageFile(sizeBytes: sourceSize)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device, verify: true)
        let context = recorder.makeContext(request: request)

        let written = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: image.device,
            context: context
        )
        try await writer.verify(
            source: try DescriptorImageSource(fileDescriptor: fd),
            against: image.device,
            bytesWritten: written,
            context: context
        )

        #expect(recorder.phases.contains(.verifying))
    }

    @Test("Verifikation erkennt ein einzelnes verfälschtes Byte")
    func verifyDetectsCorruption() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { image.detach() }

        let sourceSize = 4 * 1024 * 1024
        let sourceURL = try TestFixture.makeImageFile(sizeBytes: sourceSize)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device, verify: true)
        let context = recorder.makeContext(request: request)

        let written = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: image.device,
            context: context
        )

        // This is the counterfeit-flash scenario: the write reported success,
        // the medium did not keep the data.
        let corruptedOffset: UInt64 = 2_000_000
        try image.corruptByte(at: corruptedOffset)

        var caught: BiscuitError?
        do {
            try await writer.verify(
                source: try DescriptorImageSource(fileDescriptor: fd),
                against: image.device,
                bytesWritten: written,
                context: context
            )
        } catch let error as BiscuitError {
            caught = error
        }

        let error = try #require(caught, "Verifikation hätte fehlschlagen müssen")
        #expect(error.kind == .verificationFailed)
        // The message must name the offset: that is what distinguishes a dud
        // stick from a bad download.
        //
        // Compared against the same rendering path rather than a hard-coded
        // string: the number is grouped for the active locale, and deliberately
        // *not* pinning the language here keeps this test free of global state —
        // the suite runs in parallel with the localisation tests.
        #expect(
            error.message == L10n.t(.errorVerificationFailed, corruptedOffset),
            "erhielt: \(error.message)"
        )
    }

    @Test("Ein zu kleines Gerät wird vor dem Schreiben abgelehnt")
    func rejectsUndersizedDevice() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(8))
        defer { image.detach() }

        let sourceURL = try TestFixture.makeImageFile(sizeBytes: 16 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device)

        var caught: BiscuitError?
        do {
            _ = try await writer.write(
                source: try DescriptorImageSource(fileDescriptor: fd),
                to: image.device,
                context: recorder.makeContext(request: request)
            )
        } catch let error as BiscuitError {
            caught = error
        }

        let error = try #require(caught)
        #expect(error.kind == .deviceTooSmall)
        // Nothing may have been written: the check happens before the first
        // byte, so a half-destroyed stick is impossible in this case.
        let head = try image.readDevice(count: 4096)
        #expect(head.allSatisfy { $0 == 0 })
    }

    @Test("Abbruch stoppt den Schreibvorgang")
    func cancellationStopsWrite() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(64))
        defer { image.detach() }

        // The flag is set before the call, so the very first check trips it;
        // a large fixture would only slow the suite down.
        let sourceSize = 32 * 1024 * 1024
        let sourceURL = try TestFixture.makeImageFile(sizeBytes: sourceSize)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let cancellation = CancellationFlag()
        let request = JobRequest.test(target: image.device)
        let context = recorder.makeContext(request: request, cancellation: cancellation)

        // Cancel almost immediately; the writer checks the flag between chunks.
        cancellation.set()

        var caught: BiscuitError?
        do {
            _ = try await writer.write(
                source: try DescriptorImageSource(fileDescriptor: fd),
                to: image.device,
                context: context
            )
        } catch let error as BiscuitError {
            caught = error
        }

        let error = try #require(caught, "Abbruch hätte einen Fehler auslösen müssen")
        #expect(error.isCancellation)
    }

    @Test("Fortschritt ist monoton und endet bei 100 %")
    func progressIsMonotonic() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(64))
        defer { image.detach() }

        let sourceSize = 40 * 1024 * 1024
        let sourceURL = try TestFixture.makeImageFile(sizeBytes: sourceSize)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device)
        _ = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: fd),
            to: image.device,
            context: recorder.makeContext(request: request)
        )

        let byteCounts = recorder.progress
            .filter { $0.phase == .writing }
            .map(\.bytesProcessed)

        #expect(byteCounts.count >= 2, "zu wenige Fortschrittsmeldungen")
        // A bar that jumps backwards reads as a malfunction, so monotonicity is
        // a user-visible contract, not an implementation detail.
        for pair in zip(byteCounts, byteCounts.dropFirst()) {
            #expect(pair.0 <= pair.1, "Fortschritt lief zurück: \(pair.0) → \(pair.1)")
        }
        #expect(byteCounts.last == UInt64(sourceSize))

        let fractions = recorder.overallFractions
        #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test("Wiederholtes Schreiben überschreibt vollständig")
    func secondWriteOverwritesFirst() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(32))
        defer { image.detach() }

        let large = try TestFixture.makeImageFile(sizeBytes: 8 * 1024 * 1024, seed: 111)
        let small = try TestFixture.makeImageFile(sizeBytes: 2 * 1024 * 1024, seed: 222)
        defer {
            try? FileManager.default.removeItem(at: large)
            try? FileManager.default.removeItem(at: small)
        }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device)

        let largeFD = try TestFixture.openDescriptor(large)
        _ = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: largeFD),
            to: image.device,
            context: recorder.makeContext(request: request)
        )
        close(largeFD)

        let smallFD = try TestFixture.openDescriptor(small)
        _ = try await writer.write(
            source: try DescriptorImageSource(fileDescriptor: smallFD),
            to: image.device,
            context: recorder.makeContext(request: request)
        )
        close(smallFD)

        // The second image must be intact at the start.
        let head = try image.readDevice(count: 2 * 1024 * 1024)
        #expect(head == (try Data(contentsOf: small)))

        // Beyond it, the first image's data is still there. This is a real,
        // documented property of raw writing — not a bug, but worth pinning
        // down so nobody "fixes" it by zeroing the whole device, which would
        // take minutes on a large stick.
        let remnant = try image.readDevice(offset: 4 * 1024 * 1024, count: 4096)
        let original = try Data(contentsOf: large)
        #expect(remnant == original[(4 * 1024 * 1024)..<(4 * 1024 * 1024 + 4096)])
    }

    @Test("Ein leeres Abbild wird abgelehnt")
    func rejectsEmptySource() async throws {
        let image = try AttachedDiskImage.create(sizeBytes: .mebibytes(8))
        defer { image.detach() }

        let sourceURL = try TestFixture.makeImageFile(sizeBytes: 0)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let fd = try TestFixture.openDescriptor(sourceURL)
        defer { close(fd) }

        let recorder = JobRecorder()
        let request = JobRequest.test(target: image.device)

        await #expect(throws: BiscuitError.self) {
            _ = try await writer.write(
                source: try DescriptorImageSource(fileDescriptor: fd),
                to: image.device,
                context: recorder.makeContext(request: request)
            )
        }
    }
}
