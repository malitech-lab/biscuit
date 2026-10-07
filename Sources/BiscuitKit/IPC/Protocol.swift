import Foundation

/// Wire protocol between the unprivileged app and the privileged helper.
///
/// Transport: AF_UNIX stream socket. Framing: 4-byte big-endian unsigned length
/// prefix followed by that many bytes of JSON. Max frame size is bounded so a
/// compromised peer cannot force an unbounded allocation.
public enum IPCProtocol {
    /// Bumped whenever the wire format changes incompatibly. Both ends refuse to
    /// talk across a mismatch, which prevents a stale helper binary left over
    /// from a previous version from being driven with new semantics.
    public static let version = 1

    public static let maxFrameBytes = 4 * 1024 * 1024

    /// A helper with no active job exits after this long, so a forgotten root
    /// process cannot linger for the whole login session.
    public static let idleTimeoutSeconds: TimeInterval = 300

    /// Length of the shared secret used to authenticate the app to the helper.
    public static let tokenByteCount = 32
}

// MARK: - Requests

public enum HelperRequest: Codable, Sendable {
    /// Must be the first frame on a new connection.
    case handshake(token: String, protocolVersion: Int, clientVersion: String)
    case ping
    /// Re-read device topology from the privileged side. Used to re-validate a
    /// target immediately before destroying it.
    case inspectDevice(bsdName: String)
    /// Announces that the next `sendmsg` on this socket carries an `SCM_RIGHTS`
    /// descriptor for the named job. Must immediately precede `runJob`, and the
    /// helper performs the matching `recvmsg` before reading another frame.
    case transferSourceDescriptor(jobID: UUID)
    case runJob(JobRequest)
    case cancelJob(id: UUID)
    /// Graceful teardown; helper flushes and exits.
    case shutdown
}

// MARK: - Responses

public enum HelperResponse: Codable, Sendable {
    case handshakeAccepted(helperVersion: String, protocolVersion: Int)
    case handshakeRejected(reason: String)
    case pong
    case deviceInfo(StorageDevice)
    case deviceMissing(bsdName: String)
    case progress(JobProgress)
    case log(LogEntry)
    case jobFinished(JobResult)
    case jobFailed(jobID: UUID, error: BiscuitError)
    case failure(BiscuitError)
    case goodbye
}

// MARK: - Codable JSON configuration

public extension IPCProtocol {
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = []
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

// MARK: - Session paths

/// Filesystem layout for a single privileged session. Everything lives in a
/// 0700 directory under the user's own Application Support so that no other
/// local user can reach the socket or the token.
public struct HelperSessionPaths: Sendable {
    public let root: URL
    public let socket: URL
    public let token: URL
    public let helperLog: URL

    public init(root: URL) {
        self.root = root
        // AF_UNIX paths are capped at 104 bytes on Darwin, so keep names short.
        self.socket = root.appendingPathComponent("s")
        self.token = root.appendingPathComponent("t")
        self.helperLog = root.appendingPathComponent("helper.log")
    }

    public static func makeUnique(
        appSupport: URL,
        sessionID: UUID = UUID()
    ) -> HelperSessionPaths {
        // Short session component keeps us well inside sun_path limits.
        let short = sessionID.uuidString.prefix(8).lowercased()
        let root = appSupport
            .appendingPathComponent("run", isDirectory: true)
            .appendingPathComponent(String(short), isDirectory: true)
        return HelperSessionPaths(root: root)
    }

    /// AF_UNIX `sun_path` is a fixed 104-byte buffer on Darwin.
    public var socketPathFitsInSunPath: Bool {
        socket.path.utf8.count < 104
    }
}
