import Foundation
@testable import BiscuitKit

/// A real block device, backed by a file, for integration tests.
///
/// `hdiutil attach -nomount` on a raw image produces `/dev/diskN` and
/// `/dev/rdiskN` nodes that the attaching user may write to — no root required.
/// That makes it possible to exercise the actual write path against genuine
/// device semantics: block-size-aligned I/O, short writes, `fsync`, read-back
/// verification. None of that is covered by writing to a regular file, and all
/// of it is where a bug would silently produce an unbootable stick.
final class AttachedDiskImage {
    let backingFile: URL
    let bsdName: String
    let device: StorageDevice

    private var detached = false

    private init(backingFile: URL, bsdName: String, device: StorageDevice) {
        self.backingFile = backingFile
        self.bsdName = bsdName
        self.device = device
    }

    /// Creates a zero-filled image of `sizeBytes` and attaches it.
    static func create(sizeBytes: UInt64, blockSize: UInt32 = 512) throws -> AttachedDiskImage {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-dev-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let backingFile = directory.appendingPathComponent("device.img")
        // Sparse allocation: a 512 MiB test device costs no real disk space.
        guard FileManager.default.createFile(atPath: backingFile.path, contents: nil) else {
            throw TestDeviceError("Backing-Datei konnte nicht erstellt werden")
        }
        let handle = try FileHandle(forWritingTo: backingFile)
        try handle.truncate(atOffset: sizeBytes)
        try handle.close()

        let bsdName = try attach(backingFile)

        let device = StorageDevice(
            bsdName: bsdName,
            model: "Biscuit Test Device",
            vendor: nil,
            sizeBytes: sizeBytes,
            blockSize: blockSize,
            // Deliberately reported as USB: the eligibility rules live in
            // DiskOperations.validateTarget, which these tests do not exercise,
            // and a `.virtual` bus would be rejected there by design.
            bus: .usb,
            isRemovableMedia: true,
            isEjectable: true,
            isWritable: true,
            isSystemDisk: false,
            volumes: []
        )

        return AttachedDiskImage(backingFile: backingFile, bsdName: bsdName, device: device)
    }

    private static func attach(_ image: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "attach",
            "-nomount",
            "-noverify",
            "-noautofsck",
            "-imagekey", "diskimage-class=CRawDiskImage",
            image.path
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TestDeviceError("hdiutil attach exit \(process.terminationStatus)")
        }

        // Output looks like "/dev/disk7          \n"; the first token of the
        // first line is the whole-disk node.
        let output = String(decoding: data, as: UTF8.self)
        guard let first = output.split(separator: "\n").first,
              let path = first.split(separator: " ", omittingEmptySubsequences: true).first,
              path.hasPrefix("/dev/disk")
        else {
            throw TestDeviceError("hdiutil-Ausgabe unverständlich: \(output)")
        }
        return String(path.dropFirst("/dev/".count))
    }

    func detach() {
        guard !detached else { return }
        detached = true

        for forced in [false, true] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = forced
                ? ["detach", "/dev/\(bsdName)", "-force"]
                : ["detach", "/dev/\(bsdName)"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { break }
        }

        // A leaked attachment would hold a device node for the whole test run,
        // so cleanup is unconditional.
        try? FileManager.default.removeItem(at: backingFile.deletingLastPathComponent())
    }

    deinit {
        detach()
    }

    /// Reads `count` bytes from the device starting at `offset`, through the
    /// raw node, so the comparison sees what the hardware would.
    func readDevice(offset: UInt64 = 0, count: Int) throws -> Data {
        let fd = open(device.rawDevicePath, O_RDONLY)
        guard fd >= 0 else { throw TestDeviceError("open: errno \(errno)") }
        defer { close(fd) }

        let blockSize = Int(device.blockSize)
        let alignedOffset = (Int(offset) / blockSize) * blockSize
        let skew = Int(offset) - alignedOffset
        let span = ((skew + count + blockSize - 1) / blockSize) * blockSize

        guard lseek(fd, off_t(alignedOffset), SEEK_SET) >= 0 else {
            throw TestDeviceError("lseek: errno \(errno)")
        }

        var buffer = [UInt8](repeating: 0, count: span)
        var total = 0
        while total < span {
            let read = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fd, raw.baseAddress!.advanced(by: total), span - total)
            }
            if read <= 0 { break }
            total += read
        }
        guard total >= skew + count else {
            throw TestDeviceError("nur \(total) von \(skew + count) Bytes gelesen")
        }
        return Data(buffer[skew..<(skew + count)])
    }

    /// Overwrites a single byte on the device, to simulate media that silently
    /// drops a write.
    func corruptByte(at offset: UInt64) throws {
        let blockSize = Int(device.blockSize)
        let blockStart = (Int(offset) / blockSize) * blockSize
        let within = Int(offset) - blockStart

        let fd = open(device.rawDevicePath, O_RDWR)
        guard fd >= 0 else { throw TestDeviceError("open rw: errno \(errno)") }
        defer { close(fd) }

        var block = [UInt8](repeating: 0, count: blockSize)
        guard lseek(fd, off_t(blockStart), SEEK_SET) >= 0 else {
            throw TestDeviceError("lseek: errno \(errno)")
        }
        _ = block.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, blockSize) }

        block[within] ^= 0xFF

        guard lseek(fd, off_t(blockStart), SEEK_SET) >= 0 else {
            throw TestDeviceError("lseek back: errno \(errno)")
        }
        let written = block.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, blockSize) }
        guard written == blockSize else {
            throw TestDeviceError("Korruption nicht geschrieben: \(written)")
        }
        _ = fsync(fd)
    }
}

struct TestDeviceError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

// MARK: - Source fixtures

enum TestFixture {
    /// Writes a deterministic payload: reproducible on failure, and distinct in
    /// every 64 KiB block so a writer that drops or reorders a chunk cannot pass
    /// by accident.
    ///
    /// Built by tiling one generated block and perturbing each copy, rather than
    /// generating every byte. Tests compile at `-Onone`, where a per-byte loop
    /// runs at roughly 10 MB/s — a 200 MiB fixture then costs 19 seconds of pure
    /// setup, which is most of the suite's runtime.
    static func makeImageFile(sizeBytes: Int, seed: UInt64 = 0x5DEECE66) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-src-\(UUID().uuidString.prefix(8)).img")
        try writeImageFile(at: url, sizeBytes: sizeBytes, seed: seed)
        return url
    }

    /// Writes the same payload to a caller-chosen location.
    ///
    /// Preferred over generating into the temporary directory and moving:
    /// `FileManager.moveItem` across the boundary occasionally fails with a
    /// permission error under parallel test execution, and a flaky fixture is
    /// indistinguishable from a flaky implementation.
    static func writeImageFile(at url: URL, sizeBytes: Int, seed: UInt64 = 0x5DEECE66) throws {

        let blockSize = 64 * 1024
        var state = seed
        var template = [UInt8](repeating: 0, count: min(blockSize, max(sizeBytes, 1)))
        for index in template.indices {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            template[index] = UInt8(truncatingIfNeeded: state)
        }

        var payload = Data(capacity: sizeBytes)
        var blockIndex = 0
        while payload.count < sizeBytes {
            let remaining = sizeBytes - payload.count
            // Vary the first eight bytes per block so no two blocks are equal.
            var block = template
            withUnsafeBytes(of: UInt64(blockIndex).littleEndian) { marker in
                for offset in 0..<min(8, block.count) {
                    block[offset] ^= marker[offset]
                }
            }
            payload.append(contentsOf: block.prefix(min(remaining, block.count)))
            blockIndex += 1
        }

        try payload.write(to: url)
    }

    /// Builds a directory tree for copier tests.
    static func makeTree(
        files: [(path: String, sizeBytes: Int)]
    ) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-tree-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        for file in files {
            let target = root.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let payload = Data(
                (0..<file.sizeBytes).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ file.path.count) }
            )
            try payload.write(to: target)
        }
        return root
    }

    static func openDescriptor(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw TestDeviceError("open \(url.path): errno \(errno)") }
        return fd
    }
}

// MARK: - Progress recording

/// Collects everything a job emits so tests can assert on progress behaviour,
/// not just on the final byte count.
final class JobRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var progressUpdates: [JobProgress] = []
    private var logEntries: [LogEntry] = []
    private var results: [JobResult] = []
    private var failures: [BiscuitError] = []

    var emit: @Sendable (HelperResponse) -> Void {
        { [weak self] response in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            switch response {
            case .progress(let update): self.progressUpdates.append(update)
            case .log(let entry): self.logEntries.append(entry)
            case .jobFinished(let result): self.results.append(result)
            case .jobFailed(_, let error): self.failures.append(error)
            case .failure(let error): self.failures.append(error)
            default: break
            }
        }
    }

    var progress: [JobProgress] {
        lock.lock(); defer { lock.unlock() }
        return progressUpdates
    }

    var logs: [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return logEntries
    }

    var phases: [JobPhase] {
        progress.map(\.phase)
    }

    /// Overall fractions in emission order, ignoring indeterminate updates.
    var overallFractions: [Double] {
        progress.compactMap(\.overallFraction)
    }

    func makeContext(
        request: JobRequest,
        cancellation: CancellationFlag = CancellationFlag()
    ) -> JobContext {
        JobContext(
            request: request,
            phases: JobPhase.plan(for: request.strategy, verify: request.verifyAfterWrite),
            cancellation: cancellation,
            emit: emit
        )
    }
}

extension JobRequest {
    /// Minimal request for tests that only exercise one operation.
    static func test(
        strategy: WriteStrategy = .rawImage,
        target: StorageDevice,
        source: SourceHandle = .none,
        verify: Bool = false,
        label: String = "TEST"
    ) -> JobRequest {
        JobRequest(
            strategy: strategy,
            targetBSDName: target.bsdName,
            expectedTargetSizeBytes: target.sizeBytes,
            source: source,
            volumeLabel: label,
            partitionScheme: .gpt,
            filesystem: .fat32,
            verifyAfterWrite: verify
        )
    }
}
