import Foundation
@testable import BiscuitKit

/// Runs a real `HelperServer` against a real UNIX socket in-process, so the
/// handshake, the token check, the descriptor transfer and the connection
/// lifecycle can be exercised without root and without a device.
///
/// The server normally runs as root in a separate process. Everything that
/// *requires* root lives behind `JobRunning`, which is stubbed here — so these
/// tests cover the security-relevant transport layer exactly as it ships.
final class HelperTestHarness: @unchecked Sendable {
    let paths: HelperSessionPaths
    let token: String
    let executor: StubJobRunner

    private let root: URL
    private var server: HelperServer?
    private var serverThread: Thread?
    private let outcomeBox = OutcomeBox()

    init(
        token: String = String(repeating: "A", count: 44),
        expectedClientPrefix: String? = nil,
        acceptTimeout: TimeInterval = 10,
        idleTimeout: TimeInterval = IPCProtocol.idleTimeoutSeconds,
        executor: StubJobRunner = StubJobRunner()
    ) throws {
        // Short path: AF_UNIX `sun_path` is a fixed 104-byte buffer, and the
        // temporary directory alone is already long.
        self.root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("bfh\(UInt32.random(in: 0...0xFFFFFF))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        self.paths = HelperSessionPaths(root: root)
        self.token = token
        self.executor = executor

        let configuration = HelperServer.Configuration(
            paths: paths,
            expectedToken: token,
            expectedClientUID: getuid(),
            expectedClientPrefix: expectedClientPrefix,
            helperVersion: "test-1.0",
            acceptTimeout: acceptTimeout,
            idleTimeout: idleTimeout
        )
        self.server = HelperServer(configuration: configuration, executor: executor)
    }

    /// Binds the socket and starts serving on a dedicated thread.
    ///
    /// Bind happens synchronously so a caller can connect immediately without
    /// racing the listener into existence.
    func start() throws {
        guard let server else { return }
        try server.bind()

        let thread = Thread { [weak self] in
            guard let self else { return }
            let outcome = (try? server.serveOneClient()) ?? .clientDisconnected
            self.outcomeBox.set(outcome)
        }
        thread.stackSize = 1 << 20
        thread.start()
        serverThread = thread
    }

    /// Connects a real `HelperClient`, performing the genuine handshake.
    func connectClient(
        token overrideToken: String? = nil,
        clientVersion: String = "test-client"
    ) async throws -> HelperClient {
        try await HelperClient.connect(
            socketPath: paths.socket.path,
            token: overrideToken ?? token,
            clientVersion: clientVersion,
            timeout: 5
        )
    }

    /// Raw connection that bypasses `HelperClient`, for malformed-handshake tests.
    func connectRaw() throws -> FrameChannel {
        let fd = try UnixSocket.connectWithRetry(to: paths.socket.path, timeout: 5)
        return FrameChannel(fileDescriptor: fd)
    }

    /// Waits for the server thread to finish and returns why the session ended.
    func waitForOutcome(timeout: TimeInterval = 10) -> HelperServer.Outcome? {
        outcomeBox.wait(timeout: timeout)
    }

    var socketExists: Bool {
        FileManager.default.fileExists(atPath: paths.socket.path)
    }

    func tearDown() {
        server = nil
        try? FileManager.default.removeItem(at: root)
    }

    deinit {
        tearDown()
    }
}

private final class OutcomeBox: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: HelperServer.Outcome?

    func set(_ value: HelperServer.Outcome) {
        lock.lock()
        outcome = value
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) -> HelperServer.Outcome? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return outcome
    }
}

/// Stands in for the real `JobExecutor`.
///
/// Honours the contract the server depends on — exactly one terminal frame per
/// job — and records what it was asked to do, including whether a descriptor
/// actually arrived and whether cancellation was observed.
final class StubJobRunner: JobRunning, @unchecked Sendable {
    struct Invocation: Sendable {
        let request: JobRequest
        let hadDescriptor: Bool
        let descriptorSize: UInt64?
    }

    enum Behaviour: Sendable {
        case succeed
        case fail(BiscuitError)
        /// Emits progress, then waits to be cancelled.
        case waitForCancellation
        /// Emits progress frames and finishes.
        case emitProgress(count: Int)
    }

    private let lock = NSLock()
    private var recorded: [Invocation] = []
    private let started = DispatchSemaphore(value: 0)
    var behaviour: Behaviour = .succeed

    init(behaviour: Behaviour = .succeed) {
        self.behaviour = behaviour
    }

    var invocations: [Invocation] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    /// Blocks until a job starts, so a test can cancel one deterministically.
    func waitUntilStarted(timeout: TimeInterval = 5) -> Bool {
        started.wait(timeout: .now() + timeout) == .success
    }

    /// Records an invocation and returns the configured behaviour.
    ///
    /// Synchronous on purpose: `NSLock` is unavailable from an async context, and
    /// an actor here would change the concurrency behaviour being tested.
    private func record(_ invocation: Invocation) -> Behaviour {
        lock.lock(); defer { lock.unlock() }
        recorded.append(invocation)
        return behaviour
    }

    func execute(
        request: JobRequest,
        sourceDescriptor: Int32?,
        emit: @escaping @Sendable (HelperResponse) -> Void,
        cancellation: CancellationFlag
    ) async {
        var size: UInt64?
        if let sourceDescriptor {
            var info = stat()
            if fstat(sourceDescriptor, &info) == 0 { size = UInt64(info.st_size) }
        }

        let behaviour = record(
            Invocation(
                request: request,
                hadDescriptor: sourceDescriptor != nil,
                descriptorSize: size
            )
        )
        started.signal()

        defer { if let sourceDescriptor { close(sourceDescriptor) } }

        switch behaviour {
        case .succeed:
            emit(.jobFinished(JobResult(
                jobID: request.id, bytesWritten: 1024,
                duration: 0.1, verified: false, warnings: []
            )))

        case .fail(let error):
            emit(.jobFailed(jobID: request.id, error: error))

        case .emitProgress(let count):
            for index in 0..<count {
                emit(.progress(JobProgress(
                    jobID: request.id, phase: .writing,
                    phaseFraction: Double(index) / Double(count),
                    overallFraction: Double(index) / Double(count),
                    bytesProcessed: UInt64(index) * 1024, bytesTotal: UInt64(count) * 1024,
                    bytesPerSecond: nil, secondsRemaining: nil, detail: "chunk \(index)"
                )))
            }
            emit(.jobFinished(JobResult(
                jobID: request.id, bytesWritten: UInt64(count) * 1024,
                duration: 0.1, verified: false, warnings: []
            )))

        case .waitForCancellation:
            let deadline = Date().addingTimeInterval(8)
            while !cancellation.isSet, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            if cancellation.isSet {
                emit(.jobFailed(jobID: request.id, error: .cancelled))
            } else {
                emit(.jobFailed(
                    jobID: request.id,
                    error: BiscuitError.internalInconsistency("Abbruch kam nicht an")
                ))
            }
        }
    }
}

/// Drains a client's response stream into an array, with a deadline.
func collectResponses(
    from client: HelperClient,
    until isTerminal: @escaping @Sendable (HelperResponse) -> Bool,
    timeout: TimeInterval = 10
) async -> [HelperResponse] {
    var collected: [HelperResponse] = []
    let deadline = Date().addingTimeInterval(timeout)

    for await response in client.responses {
        collected.append(response)
        if isTerminal(response) { break }
        if Date() > deadline { break }
    }
    return collected
}
