import Foundation

/// App-side half of the IPC channel.
///
/// Reads are owned by one dedicated thread that feeds an `AsyncStream`, so SwiftUI
/// can simply `for await` over responses. Writes go straight through
/// `FrameChannel`, which serialises them internally.
public final class HelperClient: @unchecked Sendable {
    private let channel: FrameChannel
    private let continuation: AsyncStream<HelperResponse>.Continuation
    private let alive = AtomicBool(true)

    /// Every frame the helper sends, in order, until the connection closes.
    public let responses: AsyncStream<HelperResponse>

    public let helperVersion: String

    private init(
        channel: FrameChannel,
        helperVersion: String,
        responses: AsyncStream<HelperResponse>,
        continuation: AsyncStream<HelperResponse>.Continuation
    ) {
        self.channel = channel
        self.helperVersion = helperVersion
        self.responses = responses
        self.continuation = continuation
        startReader()
    }

    public var isAlive: Bool { alive.value && !channel.closed }

    // MARK: - Connecting

    /// Connects, performs the handshake, and returns a ready client.
    ///
    /// The retry loop exists because the helper is spawned asynchronously by the
    /// authorisation dialog; it typically binds its socket within ~100 ms but a
    /// loaded machine can take longer.
    public static func connect(
        socketPath: String,
        token: String,
        clientVersion: String,
        timeout: TimeInterval = 20
    ) async throws -> HelperClient {
        let fd: Int32
        do {
            fd = try UnixSocket.connectWithRetry(to: socketPath, timeout: timeout)
        } catch {
            throw BiscuitError.helperUnavailable(
                "connect to helper failed: \(error)"
            )
        }

        let channel = FrameChannel(fileDescriptor: fd)

        do {
            try channel.send(HelperRequest.handshake(
                token: token,
                protocolVersion: IPCProtocol.version,
                clientVersion: clientVersion
            ))
        } catch {
            channel.close()
            throw BiscuitError.helperUnavailable("handshake send failed: \(error)")
        }

        // The handshake reply is read synchronously, before the reader thread
        // starts, so the two cannot race for the same frame.
        let reply: HelperResponse?
        do {
            reply = try channel.receive(HelperResponse.self)
        } catch {
            channel.close()
            throw BiscuitError.helperUnavailable("handshake reply unreadable: \(error)")
        }

        switch reply {
        case .handshakeAccepted(let helperVersion, let protocolVersion):
            guard protocolVersion == IPCProtocol.version else {
                channel.close()
                throw BiscuitError.helperProtocol(
                    "helper speaks protocol \(protocolVersion), expected \(IPCProtocol.version)"
                )
            }
            var continuation: AsyncStream<HelperResponse>.Continuation!
            let stream = AsyncStream<HelperResponse>(bufferingPolicy: .unbounded) {
                continuation = $0
            }
            return HelperClient(
                channel: channel,
                helperVersion: helperVersion,
                responses: stream,
                continuation: continuation
            )

        case .handshakeRejected(let reason):
            channel.close()
            throw BiscuitError(
                kind: .privilegeDenied,
                message: t(.errorHelperRejected),
                remedy: t(.errorHelperRejectedRemedy),
                diagnostics: reason
            )

        case nil:
            channel.close()
            throw BiscuitError.helperUnavailable(
                t(.errorHelperClosedWithoutReply)
            )

        default:
            channel.close()
            throw BiscuitError.helperProtocol(
                "unexpected handshake reply: \(String(describing: reply))"
            )
        }
    }

    // MARK: - Reading

    private func startReader() {
        let channel = channel
        let continuation = continuation
        let alive = alive

        Thread.detachNewThread {
            Thread.current.name = "dev.biscuit.helper-reader"
            while true {
                let response: HelperResponse?
                do {
                    response = try channel.receive(HelperResponse.self)
                } catch {
                    break
                }
                guard let response else { break }
                continuation.yield(response)
            }
            alive.value = false
            continuation.finish()
        }
    }

    // MARK: - Writing

    public func send(_ request: HelperRequest) throws {
        guard isAlive else {
            throw BiscuitError.helperUnavailable("connection to helper is closed")
        }
        do {
            try channel.send(request)
        } catch {
            alive.value = false
            throw BiscuitError.helperUnavailable("send failed: \(error)")
        }
    }

    /// Announces and transfers an open descriptor for `jobID`.
    ///
    /// Must be called immediately before `send(.runJob(...))` for the same job.
    /// The descriptor remains owned by the caller; the kernel duplicates it into
    /// the helper.
    public func sendSourceDescriptor(jobID: UUID, descriptor: Int32) throws {
        guard isAlive else {
            throw BiscuitError.helperUnavailable("connection to helper is closed")
        }
        do {
            try channel.send(
                HelperRequest.transferSourceDescriptor(jobID: jobID),
                withDescriptor: descriptor
            )
        } catch {
            alive.value = false
            throw BiscuitError.helperUnavailable(
                "descriptor handover failed: \(error)"
            )
        }
    }

    /// Sends `shutdown` and closes the channel. Safe to call repeatedly.
    public func shutdown() async {
        guard alive.value else { return }
        try? channel.send(HelperRequest.shutdown)
        // Give the helper a moment to flush and exit before tearing the socket
        // down, so its final log line is written.
        try? await Task.sleep(nanoseconds: 200_000_000)
        alive.value = false
        channel.close()
        continuation.finish()
    }
}

/// Lock-protected boolean usable from any thread.
public final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    public init(_ initial: Bool) { storage = initial }

    public var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
