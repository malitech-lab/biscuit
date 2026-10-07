import Foundation

/// The privileged side of the IPC channel.
///
/// Threat model, stated explicitly because this runs as root:
///
/// - The socket lives in a 0700 directory inside the invoking user's own
///   Application Support tree and is itself 0600 and owned by that user, so no
///   other local account can reach it.
/// - Every connection must present a 32-byte secret that the app generated and
///   wrote to a 0600 file before the helper was launched. A process that cannot
///   read the user's home directory cannot authenticate.
/// - `getpeereid` is consulted so the kernel, not the peer, asserts who is
///   connecting; the UID must match the user who authorised the elevation.
/// - The peer's executable path must sit inside the app bundle that launched the
///   helper. This is defence in depth, not a security boundary: a process
///   already running as this user could read the token, so the real boundary is
///   the admin authorisation the user granted interactively.
/// - Exactly one connection is ever served, the listener is closed as soon as it
///   is accepted, and the helper exits when that connection drops or after an
///   idle timeout. A root process never outlives the app that needed it.
///
/// Threading: one dedicated thread owns all reads from the channel. Jobs run on
/// their own task so the reader stays responsive to `cancelJob`. Writes are
/// serialised inside `FrameChannel`.
///
/// Deliberately knows nothing about disks — see `JobRunning`. That is what makes
/// the handshake and lifecycle testable without root and without a device.
public final class HelperServer: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let paths: HelperSessionPaths
        public let expectedToken: String
        public let expectedClientUID: uid_t
        /// Path prefix the connecting client's executable must have. `nil`
        /// disables the check, which is correct for a development build that
        /// does not run from a bundle.
        public let expectedClientPrefix: String?
        public let helperVersion: String
        /// How long to wait for the first connection before giving up.
        public let acceptTimeout: TimeInterval
        /// How long an established connection may sit idle.
        public let idleTimeout: TimeInterval

        public init(
            paths: HelperSessionPaths,
            expectedToken: String,
            expectedClientUID: uid_t,
            expectedClientPrefix: String?,
            helperVersion: String,
            acceptTimeout: TimeInterval = 30,
            idleTimeout: TimeInterval = IPCProtocol.idleTimeoutSeconds
        ) {
            self.paths = paths
            self.expectedToken = expectedToken
            self.expectedClientUID = expectedClientUID
            self.expectedClientPrefix = expectedClientPrefix
            self.helperVersion = helperVersion
            self.acceptTimeout = acceptTimeout
            self.idleTimeout = idleTimeout
        }
    }

    /// Why a session ended. Surfaced so the executable can choose an exit code
    /// and tests can assert on the outcome.
    public enum Outcome: Equatable, Sendable {
        case clientDisconnected
        case shutdownRequested
        case noClientConnected
        case authenticationFailed(String)
        case idleTimeout
    }

    private let configuration: Configuration
    private let executor: any JobRunning
    private let diagnostics: any HelperDiagnostics
    private let cancellation = CancellationFlag()
    private let state = ServerState()

    private var listeningFD: Int32 = -1
    private let listenerLock = NSLock()
    private var clientFD: Int32 = -1
    /// Descriptor received via `SCM_RIGHTS`, awaiting the `runJob` it belongs to.
    private var pendingDescriptor: (jobID: UUID, fd: Int32)?

    public init(
        configuration: Configuration,
        executor: any JobRunning,
        diagnostics: any HelperDiagnostics = SilentDiagnostics()
    ) {
        self.configuration = configuration
        self.executor = executor
        self.diagnostics = diagnostics
    }

    // MARK: - Lifecycle

    /// Binds the socket. Separated from `serveOneClient` so a caller — notably a
    /// test — can know the socket exists before connecting to it.
    public func bind() throws {
        guard !hasListener else { return }
        let fd = try UnixSocket.listen(
            at: configuration.paths.socket.path,
            ownerUID: configuration.expectedClientUID
        )
        listenerLock.lock()
        listeningFD = fd
        listenerLock.unlock()
        diagnostics.write("listening on \(configuration.paths.socket.path)")
    }

    /// Accepts and serves exactly one client, then returns.
    ///
    /// Must be called from a non-cooperative thread (the process's main thread),
    /// because it parks on semaphores while async work runs on the concurrency
    /// pool.
    @discardableResult
    public func serveOneClient() throws -> Outcome {
        try bind()
        startAcceptWatchdog()

        listenerLock.lock()
        let listener = listeningFD
        listenerLock.unlock()

        // Runs on every exit path, including a thrown error: serving exactly one
        // client means the node must be gone before that client is served, so
        // nothing else can even attempt to connect.
        defer { cleanUpListener() }

        guard let accepted = try UnixSocket.accept(listener) else {
            diagnostics.write("accept stopped before a client connected")
            return .noClientConnected
        }

        cleanUpListener()
        state.markConnected()
        clientFD = accepted

        return serve(clientFD: accepted)
    }

    /// Convenience wrapper used by the executable.
    @discardableResult
    public func run() throws -> Outcome {
        try serveOneClient()
    }

    private func cleanUpListener() {
        // Read-and-clear under a lock: the accept watchdog runs on another queue
        // and must not close the same descriptor twice.
        listenerLock.lock()
        let fd = listeningFD
        listeningFD = -1
        listenerLock.unlock()

        UnixSocket.stopListening(fd, path: configuration.paths.socket.path)
    }

    private var hasListener: Bool {
        listenerLock.lock(); defer { listenerLock.unlock() }
        return listeningFD >= 0
    }

    /// Terminates the helper if no client ever connects, so a failed launch does
    /// not leave a root process parked on a socket.
    ///
    /// Implemented by closing the listener rather than calling `exit`, so the
    /// same code path is exercisable in a test.
    private func startAcceptWatchdog() {
        let deadline = DispatchTime.now() + configuration.acceptTimeout
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) { [weak self] in
            guard let self, !self.state.isConnected, self.hasListener else { return }
            self.diagnostics.write(
                "no client within \(Int(self.configuration.acceptTimeout)) s, closing listener"
            )
            // Closing is what wakes the blocked accept — `shutdown` provably does
            // not, on Darwin. `cleanUpListener` claims the descriptor under a
            // lock, so this cannot race the normal path into a double close.
            self.cleanUpListener()
        }
    }

    // MARK: - Connection handling

    private func serve(clientFD: Int32) -> Outcome {
        let channel = FrameChannel(fileDescriptor: clientFD)
        defer { channel.close() }

        if case .failure(let reason) = authenticate(clientFD: clientFD, channel: channel) {
            return .authenticationFailed(reason)
        }

        let idleWatchdog = startIdleWatchdog(channel: channel)
        let outcome = readLoop(channel: channel)
        idleWatchdog.cancel()

        // If the app vanished mid-job, stop the job and let it unwind cleanly
        // rather than leaving a half-written device with no notification.
        if state.hasActiveJob {
            diagnostics.write("client gone while a job was running; cancelling")
            cancellation.set()
            state.waitForJobCompletion(timeout: 30)
        }

        if let descriptor = pendingDescriptor {
            close(descriptor.fd)
            pendingDescriptor = nil
        }

        return outcome
    }

    /// Closes the channel if the app stops issuing requests, bounding how long
    /// root lingers.
    private func startIdleWatchdog(channel: FrameChannel) -> DispatchWorkItem {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            while !channel.closed {
                Thread.sleep(forTimeInterval: min(self.configuration.idleTimeout / 4, 15))
                if channel.closed { return }
                guard !self.state.hasActiveJob else { continue }
                let idle = Date().timeIntervalSince(self.state.lastActivity)
                if idle > self.configuration.idleTimeout {
                    self.diagnostics.write("idle for \(Int(idle)) s, closing connection")
                    self.state.markIdleTimedOut()
                    channel.close()
                    return
                }
            }
        }
        DispatchQueue.global(qos: .utility).async(execute: item)
        return item
    }

    private enum AuthenticationResult {
        case success
        case failure(String)
    }

    private func authenticate(clientFD: Int32, channel: FrameChannel) -> AuthenticationResult {
        func reject(_ reason: String, wire: String) -> AuthenticationResult {
            diagnostics.error("rejected: \(reason)")
            try? channel.send(HelperResponse.handshakeRejected(reason: wire))
            return .failure(reason)
        }

        do {
            let identity = try UnixSocket.peerIdentity(of: clientFD)
            diagnostics.write(
                "peer uid=\(identity.uid) pid=\(identity.pid) path=\(identity.executablePath ?? "?")"
            )

            guard identity.uid == configuration.expectedClientUID else {
                return reject(
                    "uid \(identity.uid) != \(configuration.expectedClientUID)",
                    wire: "uid mismatch"
                )
            }

            if let expectedPrefix = configuration.expectedClientPrefix {
                let path = identity.executablePath ?? ""
                guard path.hasPrefix(expectedPrefix) else {
                    return reject(
                        "peer path \(path) outside \(expectedPrefix)",
                        wire: "client outside expected app bundle"
                    )
                }
            }

            guard let first = try channel.receive(HelperRequest.self) else {
                return .failure("client disconnected before handshake")
            }
            guard case let .handshake(token, version, clientVersion) = first else {
                return reject("first frame was not a handshake", wire: "handshake expected")
            }
            guard version == IPCProtocol.version else {
                return reject(
                    "protocol \(version) != \(IPCProtocol.version)",
                    wire: "unsupported protocol version \(version), expected \(IPCProtocol.version)"
                )
            }
            // Compared via digests so the comparison is length-independent and
            // constant-time.
            guard Checksum.matches(
                Checksum.hash(Data(token.utf8)),
                Checksum.hash(Data(configuration.expectedToken.utf8))
            ) else {
                return reject("bad token", wire: "invalid token")
            }

            try channel.send(HelperResponse.handshakeAccepted(
                helperVersion: configuration.helperVersion,
                protocolVersion: IPCProtocol.version
            ))
            diagnostics.write("handshake accepted, client \(clientVersion)")
            state.touch()
            return .success
        } catch {
            diagnostics.error("authentication error: \(error)")
            return .failure("\(error)")
        }
    }

    /// Sole owner of reads on `channel`.
    private func readLoop(channel: FrameChannel) -> Outcome {
        let diagnostics = diagnostics
        let emit: @Sendable (HelperResponse) -> Void = { response in
            // A failed send means the app went away. The job is cancelled by the
            // disconnect path rather than here, so a partially written device
            // still gets flushed and reported.
            //
            // Aber nicht mehr stillschweigend. Eine Fassung mit `try?` hat einen
            // echten Fehlschlag unsichtbar gemacht: der Helfer arbeitete einen
            // Auftrag über sieben Minuten zu Ende und meldete „finished", während
            // die App ab Minute drei keinen einzigen Rahmen mehr erhielt und
            // „läuft" anzeigte, bis der Leerlauf-Timeout zuschlug. Im
            // Helfer-Protokoll stand dazu nichts, weil der Fehler verworfen
            // wurde. Ob Senden die Ursache war, ist weiterhin offen — aber ohne
            // diese Zeile lässt es sich nicht ausschließen.
            do {
                try channel.send(response)
            } catch {
                diagnostics.error("send failed: \(error) — frame dropped")
            }
        }

        while true {
            let request: HelperRequest?
            do {
                request = try channel.receive(HelperRequest.self)
            } catch {
                diagnostics.write("read error: \(error)")
                return state.didIdleTimeOut ? .idleTimeout : .clientDisconnected
            }
            guard let request else {
                diagnostics.write("client closed the connection")
                return state.didIdleTimeOut ? .idleTimeout : .clientDisconnected
            }
            state.touch()

            switch request {
            case .handshake:
                try? channel.send(HelperResponse.failure(
                    .helperProtocol("handshake sent twice")
                ))

            case .ping:
                try? channel.send(HelperResponse.pong)

            case .inspectDevice(let bsdName):
                handleInspect(bsdName: bsdName, channel: channel)

            case .transferSourceDescriptor(let jobID):
                receiveDescriptor(for: jobID, channel: channel)

            case .runJob(let job):
                startJob(job, emit: emit, channel: channel)

            case .cancelJob(let id):
                if state.activeJobID == id {
                    diagnostics.write("cancellation requested for \(id)")
                    cancellation.set()
                } else {
                    diagnostics.write("ignoring cancel for unknown job \(id)")
                }

            case .shutdown:
                diagnostics.write("shutdown requested")
                cancellation.set()
                state.waitForJobCompletion(timeout: 30)
                try? channel.send(HelperResponse.goodbye)
                return .shutdownRequested
            }
        }
    }

    // MARK: - Request handlers

    private func handleInspect(bsdName: String, channel: FrameChannel) {
        // Safe to block: this thread is a plain pthread, not a cooperative one,
        // and the inspection takes tens of milliseconds.
        let semaphore = DispatchSemaphore(value: 0)
        let inspector = DeviceInspector()
        Task.detached {
            defer { semaphore.signal() }
            if let device = try? await inspector.inspectDevice(bsdName: bsdName) {
                try? channel.send(HelperResponse.deviceInfo(device))
            } else {
                try? channel.send(HelperResponse.deviceMissing(bsdName: bsdName))
            }
        }
        semaphore.wait()
    }

    /// Performs the `recvmsg` that collects the descriptor the app announced.
    ///
    /// Called from the reader thread, synchronously and immediately, so the
    /// ancillary message is consumed before any further frame is read. Any other
    /// ordering would misalign the stream.
    private func receiveDescriptor(for jobID: UUID, channel: FrameChannel) {
        if let stale = pendingDescriptor {
            diagnostics.write("discarding stale descriptor for \(stale.jobID)")
            close(stale.fd)
            pendingDescriptor = nil
        }
        do {
            let fd = try DescriptorTransfer.receive(from: clientFD)
            // A descriptor that is not a readable regular file is never useful,
            // and could be a device or socket the app wants root to touch.
            var info = stat()
            guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                close(fd)
                diagnostics.error("rejected descriptor: not a regular file")
                try? channel.send(HelperResponse.failure(BiscuitError(
                    kind: .sourceUnsupported,
                    message: t(.errorSourceNotRegularFile)
                )))
                return
            }
            pendingDescriptor = (jobID, fd)
            diagnostics.write("received descriptor for \(jobID), \(info.st_size) bytes")
        } catch {
            diagnostics.error("descriptor transfer failed: \(error)")
            try? channel.send(HelperResponse.failure(
                .helperProtocol("descriptor transfer failed: \(error)")
            ))
        }
    }

    private func startJob(
        _ job: JobRequest,
        emit: @escaping @Sendable (HelperResponse) -> Void,
        channel: FrameChannel
    ) {
        // Claim the descriptor that belongs to this job, if any.
        var descriptor: Int32?
        if let pending = pendingDescriptor {
            pendingDescriptor = nil
            if pending.jobID == job.id {
                descriptor = pending.fd
            } else {
                diagnostics.write("descriptor job mismatch: \(pending.jobID) vs \(job.id)")
                close(pending.fd)
            }
        }

        if job.source.requiresDescriptorTransfer, descriptor == nil {
            try? channel.send(HelperResponse.jobFailed(
                jobID: job.id,
                error: BiscuitError.helperProtocol(
                    "source announced as a descriptor but none was transferred"
                )
            ))
            return
        }

        guard state.beginJob(job.id) else {
            if let descriptor { close(descriptor) }
            try? channel.send(HelperResponse.jobFailed(
                jobID: job.id,
                error: BiscuitError(
                    kind: .deviceBusy,
                    message: t(.errorHelperBusy),
                    remedy: t(.errorHelperBusyRemedy)
                )
            ))
            return
        }

        cancellation.reset()
        diagnostics.write(
            "starting job \(job.id) strategy=\(job.strategy.rawValue) target=\(job.targetBSDName)"
        )

        let executor = executor
        let cancellation = cancellation
        let state = state
        let diagnostics = diagnostics
        // Ownership of the descriptor passes to the executor, which closes it.
        let handedOver = descriptor

        // Runs off the reader thread so `cancelJob` can still be received.
        Task.detached(priority: .userInitiated) {
            await executor.execute(
                request: job,
                sourceDescriptor: handedOver,
                emit: emit,
                cancellation: cancellation
            )
            diagnostics.write("job \(job.id) finished")
            state.endJob()
        }
    }
}

/// Lock-protected server bookkeeping shared between the reader thread, the job
/// task and the watchdogs.
private final class ServerState: @unchecked Sendable {
    private let lock = NSLock()
    private let jobFinished = DispatchSemaphore(value: 0)
    private var connected = false
    private var activeJob: UUID?
    private var activity = Date()
    private var idleTimedOut = false

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connected
    }

    var hasActiveJob: Bool {
        lock.lock(); defer { lock.unlock() }
        return activeJob != nil
    }

    var activeJobID: UUID? {
        lock.lock(); defer { lock.unlock() }
        return activeJob
    }

    var lastActivity: Date {
        lock.lock(); defer { lock.unlock() }
        return activity
    }

    var didIdleTimeOut: Bool {
        lock.lock(); defer { lock.unlock() }
        return idleTimedOut
    }

    func markConnected() {
        lock.lock(); defer { lock.unlock() }
        connected = true
        activity = Date()
    }

    func markIdleTimedOut() {
        lock.lock(); defer { lock.unlock() }
        idleTimedOut = true
    }

    func touch() {
        lock.lock(); defer { lock.unlock() }
        activity = Date()
    }

    /// Returns false when another job is already running.
    func beginJob(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activeJob == nil else { return false }
        activeJob = id
        activity = Date()
        return true
    }

    func endJob() {
        lock.lock()
        activeJob = nil
        activity = Date()
        lock.unlock()
        jobFinished.signal()
    }

    func waitForJobCompletion(timeout: TimeInterval) {
        guard hasActiveJob else { return }
        _ = jobFinished.wait(timeout: .now() + timeout)
    }
}
