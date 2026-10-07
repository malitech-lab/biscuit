import Foundation
import Testing
@testable import BiscuitKit

/// Decompression is exercised against archives produced by the real tools, not
/// against hand-crafted fixtures: the point is to prove that the libarchive
/// which macOS ships actually handles what Raspberry Pi OS and the Linux
/// distributions publish.
@Suite("Komprimierte Abbilder")
struct CompressionTests {
    /// 6 MiB of deterministic, incompressible-ish data. Large enough to span
    /// many read blocks, small enough to keep the suite quick.
    private static let payloadSize = 6 * 1024 * 1024

    private struct Fixture {
        let directory: URL
        let original: URL
        let originalDigest: String

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    private func makeFixture() throws -> Fixture {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-cmp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = directory.appendingPathComponent("orig.img")
        try TestFixture.writeImageFile(at: original, sizeBytes: Self.payloadSize)
        let digest = try Checksum.hashFile(at: original)
        return Fixture(directory: directory, original: original, originalDigest: digest)
    }

    /// Compresses with an external tool, returning nil when it is unavailable.
    private func compress(_ fixture: Fixture, using tool: String, arguments: [String]) -> URL? {
        guard let executable = ProcessRunner.locate([
            "/usr/bin/\(tool)", "/opt/homebrew/bin/\(tool)", "/usr/local/bin/\(tool)"
        ]) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = fixture.directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return nil
    }

    /// Runs a full decompression and returns the digest plus the byte count.
    private func decompress(_ url: URL) throws -> (digest: String, bytes: Int, size: ExpandedSize) {
        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0, "konnte \(url.lastPathComponent) nicht öffnen")
        defer { close(fd) }

        let format = CompressionFormat.detect(fileDescriptor: fd)
        let reader = try DecompressingReader(fileDescriptor: fd, format: format)
        defer { reader.close() }

        var hasher = IncrementalHasher(algorithm: .sha256)
        let bufferSize = 1 << 20
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 4096)
        defer { buffer.deallocate() }

        var total = 0
        while true {
            let read = try reader.read(into: buffer, count: bufferSize)
            if read == 0 { break }
            hasher.update(UnsafeRawBufferPointer(start: buffer, count: read))
            total += read
        }
        return (hasher.finalizeHex(), total, reader.expandedSize)
    }

    // MARK: - Round trips

    @Test("gzip: Inhalt kommt bytegleich an")
    func gzipRoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "gzip", arguments: ["-k", "-f", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.gz")
        try #require(FileManager.default.fileExists(atPath: archive.path))

        let result = try decompress(archive)
        #expect(result.digest == fixture.originalDigest)
        #expect(result.bytes == Self.payloadSize)
        // ISIZE is exact below 4 GiB but still reported as approximate, because
        // the field cannot express more than that.
        #expect(result.size.value == UInt64(Self.payloadSize))
        #expect(!result.size.isTrustworthy, "gzip-ISIZE darf nicht als exakt gelten")
    }

    @Test("bzip2: Inhalt kommt bytegleich an")
    func bzip2RoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "bzip2", arguments: ["-k", "-f", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.bz2")
        try #require(FileManager.default.fileExists(atPath: archive.path))

        let result = try decompress(archive)
        #expect(result.digest == fixture.originalDigest)
        // bzip2 records nothing about the original size.
        #expect(result.size == .unknown)
    }

    @Test("xz: Inhalt bytegleich und Größe exakt aus dem Index")
    func xzRoundTrip() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "xz", arguments: ["-k", "-f", "-T0", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.xz")
        guard FileManager.default.fileExists(atPath: archive.path) else {
            Issue.record(Comment("xz nicht gefunden — brew install xz"))
            return
        }

        let result = try decompress(archive)
        #expect(result.digest == fixture.originalDigest)
        // The dominant format for Raspberry Pi and Linux ARM images, and the
        // one case where the expanded size can be trusted for a capacity check.
        #expect(result.size == .exact(UInt64(Self.payloadSize)))
        #expect(result.size.isTrustworthy)
    }

    @Test("zstd wird klar abgelehnt statt unzuverlässig zu funktionieren")
    func zstdRefused() throws {
        // libarchive on macOS is built without zstd and shells out to a `zstd`
        // program instead. The privileged helper runs with a minimal PATH that
        // does not contain it, and widening that PATH in a root process is the
        // kind of shortcut this project avoids. Measured: with PATH reduced to
        // the system directories, the filter fails with
        // "unable to run program \"zstd -d -qq\"".
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "zstd", arguments: ["-qf", "orig.img", "-o", "orig.img.zst"])
        let archive = fixture.directory.appendingPathComponent("orig.img.zst")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }

        #expect(!CompressionFormat.zstd.isSupported)

        var caught: BiscuitError?
        do { _ = try decompress(archive) } catch let error as BiscuitError { caught = error }
        let error = try #require(caught, "zstd hätte abgelehnt werden müssen")
        #expect(error.kind == .sourceUnsupported)
        // The message has to name a way forward, not just say no.
        #expect(error.remedy?.isEmpty == false)
    }

    @Test("Unkomprimiertes Abbild läuft unverändert durch")
    func uncompressedPassesThrough() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let result = try decompress(fixture.original)
        #expect(result.digest == fixture.originalDigest)
        #expect(result.size == .exact(UInt64(Self.payloadSize)))
    }

    // MARK: - Detection

    @Test("Format wird aus den Magic Bytes erkannt, nicht aus der Endung")
    func detectionByMagic() {
        // A file renamed from .img.xz to .img is still xz. Writing that raw
        // produces an unbootable disk and no error anywhere, so the extension
        // is never consulted.
        #expect(CompressionFormat.detect(magic: Data([0x1F, 0x8B, 0x08, 0x00])) == .gzip)
        #expect(CompressionFormat.detect(magic: Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])) == .xz)
        #expect(CompressionFormat.detect(magic: Data([0x42, 0x5A, 0x68, 0x39])) == .bzip2)
        #expect(CompressionFormat.detect(magic: Data([0x28, 0xB5, 0x2F, 0xFD])) == .zstd)
        #expect(CompressionFormat.detect(magic: Data([0x50, 0x4B, 0x03, 0x04])) == .zip)
        #expect(CompressionFormat.detect(magic: Data([0x00, 0x01, 0x02, 0x03])) == .none)
        #expect(CompressionFormat.detect(magic: Data()) == .none)
    }

    // MARK: - Failure modes

    @Test("Abgeschnittenes Archiv wird als Fehler gemeldet, nicht als Ende")
    func truncatedArchiveFails() throws {
        // An interrupted download must not look like a short but complete image:
        // that would write a partial disk and report success.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "gzip", arguments: ["-k", "-f", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.gz")
        try #require(FileManager.default.fileExists(atPath: archive.path))

        let full = try Data(contentsOf: archive)
        let truncated = fixture.directory.appendingPathComponent("truncated.gz")
        try full.prefix(full.count / 2).write(to: truncated)

        #expect(throws: BiscuitError.self) {
            _ = try decompress(truncated)
        }
    }

    @Test("Beschädigte Daten werden erkannt")
    func corruptedArchiveFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "gzip", arguments: ["-k", "-f", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.gz")
        try #require(FileManager.default.fileExists(atPath: archive.path))

        var bytes = [UInt8](try Data(contentsOf: archive))
        // Flip a byte well inside the compressed stream.
        bytes[bytes.count / 2] ^= 0xFF
        let corrupted = fixture.directory.appendingPathComponent("corrupt.gz")
        try Data(bytes).write(to: corrupted)

        // libarchive reads a corrupted gzip stream to the end and reports no
        // error at all — measured. The trailer CRC-32 is therefore verified in
        // DecompressingReader, which is what this expectation covers.
        var caught: BiscuitError?
        do { _ = try decompress(corrupted) } catch let error as BiscuitError { caught = error }
        let error = try #require(caught, "beschädigte Daten blieben unerkannt")
        #expect(error.kind == .checksumMismatch)
        #expect(error.diagnostics?.contains("crc32") == true)
    }

    @Test("Beschädigtes xz wird von libarchive selbst erkannt")
    func corruptedXZFails() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = compress(fixture, using: "xz", arguments: ["-k", "-f", "-T0", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.xz")
        guard FileManager.default.fileExists(atPath: archive.path) else { return }

        var bytes = [UInt8](try Data(contentsOf: archive))
        bytes[bytes.count / 2] ^= 0xFF
        let corrupted = fixture.directory.appendingPathComponent("corrupt.xz")
        try Data(bytes).write(to: corrupted)

        #expect(throws: BiscuitError.self) { _ = try decompress(corrupted) }
    }

    @Test("Der Deskriptor des Aufrufers bleibt unangetastet")
    func doesNotDisturbCallersDescriptor() throws {
        // The reader duplicates the descriptor, because the caller has already
        // used it to read magic bytes and size metadata and may use it again.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        _ = compress(fixture, using: "gzip", arguments: ["-k", "-f", "orig.img"])
        let archive = fixture.directory.appendingPathComponent("orig.img.gz")

        let fd = open(archive.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }

        _ = lseek(fd, 5, SEEK_SET)
        let reader = try DecompressingReader(fileDescriptor: fd, format: .gzip)
        reader.close()

        // Still open, and still where the caller left it.
        #expect(lseek(fd, 0, SEEK_CUR) == 5)
    }

    // MARK: - Size metadata

    @Test("gzip-Größe gilt immer als unsicher")
    func gzipSizeAlwaysApproximate() throws {
        // ISIZE stores the size modulo 2³². A 9 GiB Raspberry Pi image reports
        // about 737 MiB — plausible enough to pass a capacity check and then
        // run out of space mid-write.
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        _ = compress(fixture, using: "gzip", arguments: ["-k", "-f", "orig.img"])

        let fd = open(fixture.directory.appendingPathComponent("orig.img.gz").path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }

        let size = ExpandedSizeReader.read(format: .gzip, fileDescriptor: fd)
        guard case .approximate(let value, let caveat) = size else {
            Issue.record("erwartete .approximate, erhielt \(size)")
            return
        }
        #expect(value == UInt64(Self.payloadSize))
        #expect(caveat == "gzip_isize_modulo")
    }

    @Test("Unsinnige xz-Daten führen nicht zu einer Größenangabe")
    func xzGarbageYieldsNoSize() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-xzj-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Correct xz footer magic, nonsense index behind it. A parser that
        // trusts the length field would allocate wildly or read out of bounds.
        var bytes = [UInt8](repeating: 0xAA, count: 256)
        bytes[bytes.count - 2] = UInt8(ascii: "Y")
        bytes[bytes.count - 1] = UInt8(ascii: "Z")
        let url = directory.appendingPathComponent("fake.xz")
        try Data(bytes).write(to: url)

        let fd = open(url.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }

        #expect(ExpandedSizeReader.read(format: .xz, fileDescriptor: fd) == .unknown)
    }
}
