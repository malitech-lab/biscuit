import Foundation
import Testing
@testable import BiscuitKit

/// Exercises the wire protocol over a real `socketpair`, which is the only way
/// to cover the framing and the `SCM_RIGHTS` path meaningfully — both are
/// hand-rolled POSIX code where an off-by-one is silent until a 6 GB write
/// misaligns.
@Suite("IPC-Transport")
struct IPCTests {
    /// Creates a connected AF_UNIX stream pair.
    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        try #require(result == 0, "socketpair: errno \(errno)")
        return (fds[0], fds[1])
    }

    /// Runs `body` on a detached thread.
    ///
    /// Required for anything larger than a few kilobytes: `socketpair` buffers
    /// default to 8 KiB on Darwin (`net.local.stream.sendspace`) and cannot be
    /// raised past the system limit, so a blocking send from the same thread
    /// that is supposed to drain it deadlocks.
    private func produce(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread { body() }
        thread.stackSize = 1 << 20
        thread.start()
    }

    @Test("Frames überleben einen Roundtrip")
    func frameRoundTrip() throws {
        let (a, b) = try makePair()
        let sender = FrameChannel(fileDescriptor: a)
        let receiver = FrameChannel(fileDescriptor: b)
        defer { sender.close(); receiver.close() }

        let request = HelperRequest.handshake(
            token: "dGVzdC10b2tlbg==",
            protocolVersion: IPCProtocol.version,
            clientVersion: "1.2.3 (99)"
        )
        try sender.send(request)

        let received = try receiver.receive(HelperRequest.self)
        guard case let .handshake(token, version, clientVersion) = received else {
            Issue.record("falscher Frame-Typ: \(String(describing: received))")
            return
        }
        #expect(token == "dGVzdC10b2tlbg==")
        #expect(version == IPCProtocol.version)
        #expect(clientVersion == "1.2.3 (99)")
    }

    @Test("Mehrere Frames behalten ihre Reihenfolge")
    func frameOrdering() throws {
        let (a, b) = try makePair()
        let sender = FrameChannel(fileDescriptor: a)
        let receiver = FrameChannel(fileDescriptor: b)
        defer { sender.close(); receiver.close() }

        let jobID = UUID()
        produce {
            for index in 0..<50 {
                try? sender.send(HelperResponse.progress(JobProgress(
                    jobID: jobID,
                    phase: .writing,
                    phaseFraction: Double(index) / 50,
                    overallFraction: Double(index) / 50,
                    bytesProcessed: UInt64(index) * 1024,
                    bytesTotal: 51200,
                    bytesPerSecond: 1024,
                    secondsRemaining: nil,
                    detail: "chunk \(index)"
                )))
            }
        }

        for index in 0..<50 {
            let frame = try receiver.receive(HelperResponse.self)
            guard case let .progress(progress) = frame else {
                Issue.record("Frame \(index) hatte den falschen Typ")
                return
            }
            #expect(progress.bytesProcessed == UInt64(index) * 1024)
            #expect(progress.detail == "chunk \(index)")
        }
    }

    @Test("EOF liefert nil statt eines Fehlers")
    func cleanEOF() throws {
        let (a, b) = try makePair()
        let sender = FrameChannel(fileDescriptor: a)
        let receiver = FrameChannel(fileDescriptor: b)
        defer { receiver.close() }

        sender.close()
        let frame = try receiver.receive(HelperRequest.self)
        #expect(frame == nil)
    }

    @Test("Übergroße Frames werden abgelehnt, nicht alloziert")
    func oversizedFrameRejected() throws {
        let (a, b) = try makePair()
        let receiver = FrameChannel(fileDescriptor: b)
        defer { receiver.close(); close(a) }

        // Hand-craft a header claiming a frame far beyond the cap. Without the
        // bound check this would attempt a 4 GiB allocation.
        var header = UInt32(0xFFFF_FFFF).bigEndian
        withUnsafeBytes(of: &header) { bytes in
            _ = Darwin.send(a, bytes.baseAddress, bytes.count, 0)
        }

        #expect(throws: FrameChannel.ChannelError.self) {
            _ = try receiver.receive(HelperRequest.self)
        }
    }

    @Test("Ein Frame weit über der Puffergröße wird vollständig übertragen")
    func largeFrameSpansMultipleWrites() throws {
        let (a, b) = try makePair()
        let sender = FrameChannel(fileDescriptor: a)
        let receiver = FrameChannel(fileDescriptor: b)
        defer { sender.close(); receiver.close() }

        // 2 MiB against an 8 KiB socket buffer forces several hundred partial
        // writes, which is exactly the path `writeAll` and `readExactly` exist
        // to handle. A short-write bug would truncate silently here.
        let padding = String(repeating: "x", count: 2 * 1024 * 1024)
        let entry = LogEntry(level: .info, source: "test", message: padding)
        produce { try? sender.send(HelperResponse.log(entry)) }

        let frame = try receiver.receive(HelperResponse.self)
        guard case let .log(decoded) = frame else {
            Issue.record("falscher Frame-Typ")
            return
        }
        #expect(decoded.message.count == padding.count)
        #expect(decoded.message == padding)
    }
}

@Suite("Deskriptor-Übergabe")
struct DescriptorTransferTests {
    private func makePair() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (fds[0], fds[1])
    }

    @Test("Ein Deskriptor überquert den Socket und bleibt lesbar")
    func descriptorRoundTrip() throws {
        let (a, b) = try makePair()
        defer { close(a); close(b) }

        let payload = Data("biscuit descriptor transfer".utf8)
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-fd-\(UUID().uuidString).bin")
        try payload.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let original = open(temporary.path, O_RDONLY)
        try #require(original >= 0)
        defer { close(original) }

        try DescriptorTransfer.send(descriptor: original, over: a)
        let received = try DescriptorTransfer.receive(from: b)
        try #require(received >= 0)
        defer { close(received) }

        // Must be a distinct descriptor number in this process but refer to the
        // same inode.
        var originalInfo = stat()
        var receivedInfo = stat()
        try #require(fstat(original, &originalInfo) == 0)
        try #require(fstat(received, &receivedInfo) == 0)
        #expect(originalInfo.st_ino == receivedInfo.st_ino)
        #expect(originalInfo.st_size == receivedInfo.st_size)

        var buffer = [UInt8](repeating: 0, count: payload.count)
        let read = Darwin.read(received, &buffer, buffer.count)
        #expect(read == payload.count)
        #expect(Data(buffer) == payload)
    }

    @Test("Deskriptor direkt nach einem Frame kommt korrekt an")
    func interleavedWithFrame() throws {
        // This is the exact sequence the real protocol uses: a frame announcing
        // the transfer, then the ancillary message. It only works because
        // FrameChannel reads exactly the bytes it needs and never buffers ahead.
        let (a, b) = try makePair()
        let sender = FrameChannel(fileDescriptor: a)
        let receiver = FrameChannel(fileDescriptor: b)
        defer { sender.close(); receiver.close() }

        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-fd-\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 4096).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let fileFD = open(temporary.path, O_RDONLY)
        try #require(fileFD >= 0)
        defer { close(fileFD) }

        let jobID = UUID()
        try sender.send(
            HelperRequest.transferSourceDescriptor(jobID: jobID),
            withDescriptor: fileFD
        )
        try sender.send(HelperRequest.ping)

        let announcement = try receiver.receive(HelperRequest.self)
        guard case let .transferSourceDescriptor(receivedJobID) = announcement else {
            Issue.record("erwartete Ankündigung, erhielt \(String(describing: announcement))")
            return
        }
        #expect(receivedJobID == jobID)

        let descriptor = try DescriptorTransfer.receive(from: b)
        try #require(descriptor >= 0)
        defer { close(descriptor) }

        var info = stat()
        try #require(fstat(descriptor, &info) == 0)
        #expect(info.st_size == 4096)

        // The frame that followed the ancillary message must still be intact.
        let next = try receiver.receive(HelperRequest.self)
        guard case .ping = next else {
            Issue.record("Stream nach Deskriptor-Übergabe verschoben: \(String(describing: next))")
            return
        }
    }
}

@Suite("Sitzungspfade")
struct HelperSessionPathsTests {
    @Test("Socket-Pfad bleibt unter der AF_UNIX-Grenze")
    func sunPathLimit() {
        let appSupport = URL(fileURLWithPath: "/Users/einbenutzername/Library/Application Support/Biscuit")
        let paths = HelperSessionPaths.makeUnique(appSupport: appSupport)
        #expect(paths.socketPathFitsInSunPath)
        #expect(paths.socket.path.utf8.count < 104)
    }

    @Test("Jede Sitzung erhält ein eigenes Verzeichnis")
    func uniquePerSession() {
        let appSupport = URL(fileURLWithPath: "/tmp/bf")
        let first = HelperSessionPaths.makeUnique(appSupport: appSupport)
        let second = HelperSessionPaths.makeUnique(appSupport: appSupport)
        #expect(first.root != second.root)
    }
}

/// Guards against process-global side effects in socket setup.
@Suite("Socket-Nebenwirkungen")
struct UnixSocketSideEffectTests {
    /// `listen` must not disturb file creation happening on other threads.
    ///
    /// An earlier version set `umask(0o177)` around `bind` to get a restrictive
    /// mode onto the socket node. But `umask` is per-process: a directory
    /// created by another thread inside that window came out without its
    /// execute bit, and writing into it then failed with `EPERM` — surfacing as
    /// an unrelated test failing perhaps one run in thirty.
    @Test("listen verändert die umask nicht")
    func listenLeavesUmaskAlone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-umask-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Read the mask without leaving it changed: it can only be queried by
        // setting it.
        let before = umask(0o022)
        umask(before)

        let socketPath = root.appendingPathComponent("s.sock").path
        let fd = try UnixSocket.listen(at: socketPath, ownerUID: getuid())
        defer { Darwin.close(fd); unlink(socketPath) }

        let after = umask(0o022)
        umask(after)
        #expect(after == before, "umask wurde verändert: \(before) → \(after)")

        // The guarantee that actually matters, verified rather than assumed.
        var info = stat()
        #expect(stat(socketPath, &info) == 0)
        #expect(info.st_mode & 0o777 == 0o600, "Socket-Modus nicht 0600")
    }

    /// The failure mode the removed `umask` caused, reproduced directly.
    @Test("Nebenläufige Verzeichnisse bleiben beschreibbar")
    func concurrentDirectoryCreationStaysWritable() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bsc-race-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }

        // Hammer listen on one task while another creates directories and
        // writes into them. With the umask present this fails quickly.
        let sockets = Task.detached {
            for index in 0..<40 {
                let path = root.appendingPathComponent("s\(index).sock").path
                guard let fd = try? UnixSocket.listen(at: path, ownerUID: getuid()) else {
                    continue
                }
                Darwin.close(fd)
                unlink(path)
            }
        }

        let writes = Task.detached {
            var failures: [String] = []
            for index in 0..<40 {
                let directory = root.appendingPathComponent("d\(index)")
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true
                    )
                    try Data("x".utf8).write(to: directory.appendingPathComponent("f.txt"))
                } catch {
                    failures.append("d\(index): \(error.localizedDescription)")
                }
            }
            return failures
        }

        await sockets.value
        let failures = await writes.value
        #expect(failures.isEmpty, "Schreibfehler: \(failures.prefix(3).joined(separator: "; "))")
    }
}
