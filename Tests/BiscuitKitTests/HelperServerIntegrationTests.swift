import Foundation
import Testing
@testable import BiscuitKit

/// End-to-end tests of the privilege boundary's transport layer: a real
/// `HelperServer` on a real UNIX socket, talked to by the real `HelperClient`.
///
/// This is the layer that decides who may command a root process, so it is
/// tested as it ships rather than by inspection. Only the job implementation is
/// stubbed, because that is the part that genuinely needs root.
@Suite("Helfer-Transport und Autorisierung", .serialized)
struct HelperServerIntegrationTests {
    // MARK: - Handshake

    @Test("Gültiger Handshake wird akzeptiert")
    func validHandshakeSucceeds() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        #expect(client.isAlive)
        #expect(client.helperVersion == "test-1.0")

        try client.send(.ping)
        let responses = await collectResponses(from: client) { response in
            if case .pong = response { return true }
            return false
        }
        #expect(responses.contains { if case .pong = $0 { return true } else { return false } })

        await client.shutdown()
    }

    @Test("Falsches Token wird abgelehnt")
    func wrongTokenRejected() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        var caught: BiscuitError?
        do {
            _ = try await harness.connectClient(token: String(repeating: "B", count: 44))
        } catch let error as BiscuitError {
            caught = error
        }

        let error = try #require(caught, "Verbindung hätte abgelehnt werden müssen")
        #expect(error.kind == .privilegeDenied)
        // Protocol reasons are diagnostics and therefore English and stable:
        // they end up in bug reports, where a translated string would be
        // harder to compare across machines.
        #expect(error.diagnostics?.contains("invalid token") == true)

        let outcome = harness.waitForOutcome()
        #expect(outcome == .authenticationFailed("bad token"))
    }

    @Test("Ein leeres Token wird nicht als Treffer gewertet")
    func emptyTokenRejected() async throws {
        // Guards against a comparison that treats two empty strings as equal, or
        // one that short-circuits on length.
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        await #expect(throws: BiscuitError.self) {
            _ = try await harness.connectClient(token: "")
        }
    }

    @Test("Falsche Protokollversion wird abgelehnt")
    func protocolMismatchRejected() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        // Bypass HelperClient so a wrong version can be sent deliberately: a
        // stale helper left over from a previous install must never be driven
        // with new semantics.
        let channel = try harness.connectRaw()
        defer { channel.close() }

        try channel.send(HelperRequest.handshake(
            token: harness.token,
            protocolVersion: IPCProtocol.version + 99,
            clientVersion: "test"
        ))

        let reply = try channel.receive(HelperResponse.self)
        guard case let .handshakeRejected(reason) = reply else {
            Issue.record("erwartete Ablehnung, erhielt \(String(describing: reply))")
            return
        }
        #expect(reason.contains("unsupported protocol version"))
    }

    @Test("Ein anderer Frame als der Handshake wird abgelehnt")
    func nonHandshakeFirstFrameRejected() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let channel = try harness.connectRaw()
        defer { channel.close() }

        try channel.send(HelperRequest.ping)

        let reply = try channel.receive(HelperResponse.self)
        guard case let .handshakeRejected(reason) = reply else {
            Issue.record("erwartete Ablehnung, erhielt \(String(describing: reply))")
            return
        }
        #expect(reason.contains("handshake expected"))
    }

    @Test("Client außerhalb des erwarteten Bundles wird abgelehnt")
    func clientPathPrefixEnforced() async throws {
        // The test process lives under .build, so an /Applications prefix cannot
        // match. This proves the check is actually applied rather than skipped.
        let harness = try HelperTestHarness(
            expectedClientPrefix: "/Applications/DefinitelyNotHere.app"
        )
        defer { harness.tearDown() }
        try harness.start()

        await #expect(throws: BiscuitError.self) {
            _ = try await harness.connectClient()
        }

        let outcome = harness.waitForOutcome()
        if case .authenticationFailed(let reason) = outcome {
            #expect(reason.contains("outside"))
        } else {
            Issue.record("erwartete Authentifizierungsfehler, erhielt \(String(describing: outcome))")
        }
    }

    @Test("Nach der ersten Verbindung ist der Socket verschwunden")
    func onlyOneConnectionIsServed() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        #expect(harness.socketExists)
        let client = try await harness.connectClient()
        defer { Task { await client.shutdown() } }

        // The listener is closed and the node unlinked the moment a client is
        // accepted, so nothing else can even attempt to connect.
        var vanished = false
        for _ in 0..<50 where !vanished {
            if !harness.socketExists { vanished = true; break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(vanished, "Socket-Knoten existiert nach dem Accept weiterhin")

        #expect(throws: (any Error).self) {
            _ = try UnixSocket.connect(to: harness.paths.socket.path)
        }
    }

    @Test("Socket hat Modus 0600 und gehört dem Benutzer")
    func socketPermissions() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        var info = stat()
        try #require(lstat(harness.paths.socket.path, &info) == 0)
        #expect((info.st_mode & 0o777) == 0o600)
        #expect(info.st_uid == getuid())
    }

    // MARK: - Job dispatch

    @Test("Auftrag wird ausgeführt und genau ein Abschluss-Frame gesendet")
    func jobDispatchEmitsExactlyOneTerminalFrame() async throws {
        let harness = try HelperTestHarness(
            executor: StubJobRunner(behaviour: .emitProgress(count: 5))
        )
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        let request = JobRequest.test(
            strategy: .eraseOnly,
            target: Self.device,
            source: .none
        )
        try client.send(.runJob(request))

        let responses = await collectResponses(from: client) { response in
            switch response {
            case .jobFinished, .jobFailed: return true
            default: return false
            }
        }

        let terminals = responses.filter { response in
            switch response {
            case .jobFinished, .jobFailed: return true
            default: return false
            }
        }
        #expect(terminals.count == 1, "genau ein Abschluss-Frame erwartet")

        let progressFrames = responses.filter {
            if case .progress = $0 { return true } else { return false }
        }
        #expect(progressFrames.count == 5)

        #expect(harness.executor.invocations.count == 1)
        #expect(harness.executor.invocations.first?.request.id == request.id)

        await client.shutdown()
    }

    @Test("Ein zweiter Auftrag während eines laufenden wird abgewiesen")
    func concurrentJobRejected() async throws {
        let harness = try HelperTestHarness(
            executor: StubJobRunner(behaviour: .waitForCancellation)
        )
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        let first = JobRequest.test(strategy: .eraseOnly, target: Self.device)
        let second = JobRequest.test(strategy: .eraseOnly, target: Self.device)

        try client.send(.runJob(first))
        #expect(harness.executor.waitUntilStarted())

        try client.send(.runJob(second))

        var sawBusy = false
        var sawFirstTerminal = false
        let deadline = Date().addingTimeInterval(10)

        for await response in client.responses {
            if case .jobFailed(let id, let error) = response {
                if id == second.id, error.kind == .deviceBusy { sawBusy = true }
                if id == first.id { sawFirstTerminal = true }
            }
            if sawBusy, !sawFirstTerminal {
                // Cancel the first so the test does not wait out the stub's own
                // deadline.
                try client.send(.cancelJob(id: first.id))
            }
            if sawBusy, sawFirstTerminal { break }
            if Date() > deadline { break }
        }

        #expect(sawBusy, "zweiter Auftrag hätte abgewiesen werden müssen")
        #expect(harness.executor.invocations.count == 1)

        await client.shutdown()
    }

    @Test("Abbruch erreicht den laufenden Auftrag")
    func cancellationReachesJob() async throws {
        let harness = try HelperTestHarness(
            executor: StubJobRunner(behaviour: .waitForCancellation)
        )
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        let request = JobRequest.test(strategy: .eraseOnly, target: Self.device)
        try client.send(.runJob(request))

        // The reader thread must stay responsive while a job runs — that is the
        // whole reason jobs are dispatched off it.
        #expect(harness.executor.waitUntilStarted())
        try client.send(.cancelJob(id: request.id))

        let responses = await collectResponses(from: client) { response in
            if case .jobFailed = response { return true }
            return false
        }

        let failure = responses.compactMap { response -> BiscuitError? in
            if case .jobFailed(_, let error) = response { return error }
            return nil
        }.first
        let error = try #require(failure)
        #expect(error.isCancellation, "Abbruch kam nicht beim Auftrag an: \(error.message)")

        await client.shutdown()
    }

    @Test("Abbruch für einen unbekannten Auftrag wird ignoriert")
    func cancelForUnknownJobIgnored() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        try client.send(.cancelJob(id: UUID()))
        // Connection must survive; a stray cancel is not a protocol violation.
        try client.send(.ping)

        let responses = await collectResponses(from: client) { response in
            if case .pong = response { return true }
            return false
        }
        #expect(responses.contains { if case .pong = $0 { return true } else { return false } })

        await client.shutdown()
    }

    // MARK: - Descriptor transfer

    @Test("Deskriptor erreicht den Auftrag über die Privilegiengrenze")
    func descriptorReachesJob() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let payload = try TestFixture.makeImageFile(sizeBytes: 128 * 1024)
        defer { try? FileManager.default.removeItem(at: payload) }
        let fd = try TestFixture.openDescriptor(payload)
        defer { close(fd) }

        let client = try await harness.connectClient()
        let request = JobRequest.test(
            strategy: .rawImage,
            target: Self.device,
            source: .transferredDescriptor(sizeBytes: 128 * 1024, displayName: "test.img")
        )

        try client.sendSourceDescriptor(jobID: request.id, descriptor: fd)
        try client.send(.runJob(request))

        _ = await collectResponses(from: client) { response in
            switch response {
            case .jobFinished, .jobFailed: return true
            default: return false
            }
        }

        let invocation = try #require(harness.executor.invocations.first)
        #expect(invocation.hadDescriptor, "kein Deskriptor beim Auftrag angekommen")
        // Proof it is the same file, not merely some descriptor.
        #expect(invocation.descriptorSize == 128 * 1024)

        await client.shutdown()
    }

    @Test("Angekündigter, aber nicht übergebener Deskriptor führt zum Fehler")
    func missingDescriptorFailsJob() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        let request = JobRequest.test(
            strategy: .rawImage,
            target: Self.device,
            source: .transferredDescriptor(sizeBytes: 1024, displayName: "x.img")
        )
        // Deliberately skip the transfer.
        try client.send(.runJob(request))

        let responses = await collectResponses(from: client) { response in
            if case .jobFailed = response { return true }
            return false
        }
        let error = responses.compactMap { response -> BiscuitError? in
            if case .jobFailed(_, let error) = response { return error }
            return nil
        }.first
        #expect(error?.kind == .helperProtocol)
        #expect(harness.executor.invocations.isEmpty, "Auftrag hätte nicht starten dürfen")

        await client.shutdown()
    }

    @Test("Ein Verzeichnis-Deskriptor wird abgelehnt")
    func directoryDescriptorRejected() async throws {
        // Only a regular file is ever useful. Anything else could be a device or
        // socket the app wants root to touch.
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
        let fd = open(directory.path, O_RDONLY)
        try #require(fd >= 0)
        defer { close(fd) }

        let client = try await harness.connectClient()
        let request = JobRequest.test(
            strategy: .rawImage,
            target: Self.device,
            source: .transferredDescriptor(sizeBytes: 0, displayName: "dir")
        )
        try client.sendSourceDescriptor(jobID: request.id, descriptor: fd)

        let responses = await collectResponses(from: client) { response in
            if case .failure = response { return true }
            return false
        }
        let rejection = responses.compactMap { response -> BiscuitError? in
            if case .failure(let error) = response { return error }
            return nil
        }.first
        #expect(rejection?.kind == .sourceUnsupported)

        await client.shutdown()
    }

    // MARK: - Lifecycle

    @Test("shutdown beendet die Sitzung mit goodbye")
    func shutdownIsAcknowledged() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        try client.send(.shutdown)

        let responses = await collectResponses(from: client) { response in
            if case .goodbye = response { return true }
            return false
        }
        #expect(responses.contains { if case .goodbye = $0 { return true } else { return false } })
        #expect(harness.waitForOutcome() == .shutdownRequested)
    }

    @Test("Verbindungsabbruch des Clients beendet die Sitzung")
    func clientDisconnectEndsSession() async throws {
        let harness = try HelperTestHarness()
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        try client.send(.ping)
        _ = await collectResponses(from: client) { response in
            if case .pong = response { return true }
            return false
        }

        // Drop the connection without a graceful shutdown: the helper must not
        // outlive the app that needed it.
        await client.shutdown()
        #expect(harness.waitForOutcome() != nil, "Sitzung endete nicht nach Verbindungsabbruch")
    }

    @Test("Ohne Verbindung gibt der Server den Socket frei")
    func acceptTimeoutReleasesSocket() async throws {
        let harness = try HelperTestHarness(acceptTimeout: 0.5)
        defer { harness.tearDown() }
        try harness.start()

        // A failed launch must not leave a root process parked on a socket.
        let outcome = harness.waitForOutcome(timeout: 10)
        #expect(outcome == .noClientConnected)
        #expect(!harness.socketExists)
    }

    @Test("Untätige Verbindung läuft in das Zeitlimit")
    func idleTimeoutClosesConnection() async throws {
        let harness = try HelperTestHarness(idleTimeout: 1)
        defer { harness.tearDown() }
        try harness.start()

        let client = try await harness.connectClient()
        _ = client

        // Bounds how long root lingers when the app stops asking for anything.
        let outcome = harness.waitForOutcome(timeout: 15)
        #expect(outcome == .idleTimeout, "erhielt \(String(describing: outcome))")
    }

    // MARK: -

    private static let device = StorageDevice(
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

@Suite("Sitzungs-Validierung des Helfers")
struct HelperSessionValidatorTests {
    private func makeDirectory(mode: Int) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("bfv\(UInt32.random(in: 0...0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: mode]
        )
        return url
    }

    @Test("Korrektes 0700-Verzeichnis wird akzeptiert")
    func validDirectory() throws {
        let url = try makeDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: url) }
        try HelperSessionValidator.validateSessionDirectory(at: url, expectedUID: getuid())
    }

    @Test("Zu offene Rechte werden abgelehnt")
    func tooPermissiveDirectory() throws {
        // 0755 would let any local user read the token.
        for mode in [0o755, 0o777, 0o750, 0o701] {
            let url = try makeDirectory(mode: mode)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: HelperSessionValidator.ValidationError.self) {
                try HelperSessionValidator.validateSessionDirectory(
                    at: url, expectedUID: getuid()
                )
            }
        }
    }

    @Test("Fremder Eigentümer wird abgelehnt")
    func wrongOwner() throws {
        let url = try makeDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: url) }
        // UID 0 is never this process's owner, so the check must trip.
        #expect(throws: HelperSessionValidator.ValidationError.self) {
            try HelperSessionValidator.validateSessionDirectory(at: url, expectedUID: 0)
        }
    }

    @Test("Ein Symlink wird nicht als Verzeichnis akzeptiert")
    func symlinkRejected() throws {
        // The attack this exists to stop: pre-create the session path as a link
        // into a directory the attacker controls, and root follows it.
        let real = try makeDirectory(mode: 0o700)
        defer { try? FileManager.default.removeItem(at: real) }

        let link = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("bfl\(UInt32.random(in: 0...0xFFFFFF))")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: link) }

        #expect(throws: HelperSessionValidator.ValidationError.self) {
            try HelperSessionValidator.validateSessionDirectory(at: link, expectedUID: getuid())
        }
    }

    @Test("Fehlendes Verzeichnis wird abgelehnt")
    func missingDirectory() {
        #expect(throws: HelperSessionValidator.ValidationError.self) {
            try HelperSessionValidator.validateSessionDirectory(
                at: URL(fileURLWithPath: "/tmp/bf-does-not-exist-\(UUID().uuidString)"),
                expectedUID: getuid()
            )
        }
    }

    // MARK: - Token

    private func writeToken(_ contents: String, mode: Int) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("bft\(UInt32.random(in: 0...0xFFFFFF))")
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return url
    }

    @Test("Gültiges Token wird gelesen")
    func validToken() throws {
        let expected = String(repeating: "Z", count: 44)
        let url = try writeToken(expected, mode: 0o600)
        defer { try? FileManager.default.removeItem(at: url) }
        let token = try HelperSessionValidator.readToken(at: url, expectedUID: getuid())
        #expect(token == expected)
    }

    @Test("Token mit zu offenen Rechten wird abgelehnt")
    func tokenPermissions() throws {
        for mode in [0o644, 0o666, 0o640, 0o700] {
            let url = try writeToken(String(repeating: "Z", count: 44), mode: mode)
            defer { try? FileManager.default.removeItem(at: url) }
            #expect(throws: HelperSessionValidator.ValidationError.self) {
                _ = try HelperSessionValidator.readToken(at: url, expectedUID: getuid())
            }
        }
    }

    @Test("Zu kurzes Token wird abgelehnt")
    func shortToken() throws {
        // 32 random bytes base64-encode to 44 characters; anything much shorter
        // was not produced the way the app produces it.
        let url = try writeToken("kurz", mode: 0o600)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: HelperSessionValidator.ValidationError.self) {
            _ = try HelperSessionValidator.readToken(at: url, expectedUID: getuid())
        }
    }

    @Test("Umgebender Leerraum wird entfernt")
    func tokenIsTrimmed() throws {
        let expected = String(repeating: "Q", count: 44)
        let url = try writeToken("\n  \(expected)  \n", mode: 0o600)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try HelperSessionValidator.readToken(at: url, expectedUID: getuid()) == expected)
    }

    @Test("Ein Verzeichnis ist kein Token")
    func directoryIsNotAToken() throws {
        let url = try makeDirectory(mode: 0o600)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: HelperSessionValidator.ValidationError.self) {
            _ = try HelperSessionValidator.readToken(at: url, expectedUID: getuid())
        }
    }
}
