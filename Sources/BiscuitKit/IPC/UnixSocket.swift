import Foundation

/// Thin, dependency-free wrapper around AF_UNIX stream sockets with the peer
/// credential checks we rely on for authorisation.
public enum UnixSocket {
    public enum SocketError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case posix(Int32, String)

        public var description: String {
            switch self {
            case .pathTooLong(let path):
                return "socket path too long (\(path.utf8.count) > 103 bytes): \(path)"
            case .posix(let code, let op):
                return "\(op): errno \(code) (\(String(cString: strerror(code))))"
            }
        }
    }

    private static func makeAddress(path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            guard let base = raw.baseAddress else { return }
            base.copyMemory(from: bytes.withUnsafeBytes { $0.baseAddress! }, byteCount: bytes.count)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func withAddress<R>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> R
    ) throws -> R {
        var address = try makeAddress(path: path)
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                try body(rebound, length)
            }
        }
    }

    // MARK: - Server (helper side)

    /// Creates, binds and listens on `path`. Removes any stale socket file first.
    /// The socket is created with mode 0600 and then chowned to `ownerUID` so
    /// that exactly one local user can connect.
    public static func listen(
        at path: String,
        ownerUID: uid_t,
        backlog: Int32 = 4
    ) throws -> Int32 {
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.posix(errno, "socket") }

        // Deliberately no `umask` here, though it is the textbook way to get a
        // restrictive mode onto the socket node at creation time.
        //
        // `umask` is per-process, not per-thread. Setting it around `bind`
        // means every *unrelated* file or directory another thread creates in
        // that window also gets the restrictive mask. A directory created
        // during the window comes out without its execute bit, and writing
        // anything inside it then fails with `EPERM` — far from the socket, and
        // long after the mask has been restored. That surfaced as a test in a
        // different suite failing to write a file into a directory it had just
        // created successfully.
        //
        // It is safe to drop because the mode does not carry the guarantee on
        // its own: the socket is bound inside the session directory, which is
        // created 0700 and which `HelperSessionValidator` refuses to use unless
        // it is still exactly 0700 and owned by the right user. No other user
        // can traverse into it, so the brief window between `bind` and `chmod`
        // is not reachable. The explicit `chmod` below then sets the final mode.
        do {
            try withAddress(path: path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw SocketError.posix(errno, "bind")
                }
            }
            guard Darwin.listen(fd, backlog) == 0 else {
                throw SocketError.posix(errno, "listen")
            }
            guard chmod(path, 0o600) == 0 else {
                throw SocketError.posix(errno, "chmod")
            }
            guard chown(path, ownerUID, gid_t.max) == 0 else {
                throw SocketError.posix(errno, "chown")
            }
        } catch {
            Darwin.close(fd)
            unlink(path)
            throw error
        }
        return fd
    }

    /// Blocking accept. Returns `nil` once the listening socket is closed.
    ///
    /// On the errno values treated as "stopped" rather than as failures: the
    /// behaviour here was established by experiment on Darwin, because it is not
    /// what one would guess.
    ///
    /// - `shutdown(2)` on a listening AF_UNIX socket does **not** wake a thread
    ///   parked in `accept`. It stays blocked indefinitely.
    /// - `close(2)` from another thread **does** wake it, and `accept` then fails
    ///   with `ECONNABORTED` (53) — not `EBADF`, which is the intuitive guess.
    ///
    /// Treating `ECONNABORTED` as a thrown error, as an earlier version did,
    /// turned an orderly shutdown into a propagating failure and defeated the
    /// accept timeout entirely.
    public static func accept(_ listeningFD: Int32) throws -> Int32? {
        while true {
            let fd = Darwin.accept(listeningFD, nil, nil)
            if fd >= 0 { return fd }
            let err = errno
            if err == EINTR { continue }
            if err == ECONNABORTED || err == EBADF || err == EINVAL { return nil }
            throw SocketError.posix(err, "accept")
        }
    }

    /// Closes a listening socket and removes its node.
    ///
    /// Closing is also the only way to wake a thread blocked in `accept`, so
    /// this doubles as the stop signal for an accept loop. The caller must
    /// ensure it happens exactly once — see `HelperServer.cleanUpListener`.
    public static func stopListening(_ listeningFD: Int32, path: String?) {
        if listeningFD >= 0 {
            Darwin.close(listeningFD)
        }
        if let path { unlink(path) }
    }

    // MARK: - Client (app side)

    public static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.posix(errno, "socket") }
        do {
            try withAddress(path: path) { address, length in
                while Darwin.connect(fd, address, length) != 0 {
                    if errno == EINTR { continue }
                    throw SocketError.posix(errno, "connect")
                }
            }
        } catch {
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    /// Retries `connect` until the helper has bound its socket, or the deadline
    /// passes. The helper is launched asynchronously, so some wait is expected.
    public static func connectWithRetry(
        to path: String,
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05
    ) throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: any Error = SocketError.posix(ENOENT, "connect")
        while Date() < deadline {
            do {
                return try connect(to: path)
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: pollInterval)
            }
        }
        throw lastError
    }

    // MARK: - Peer identity

    public struct PeerIdentity: Sendable {
        public let uid: uid_t
        public let gid: gid_t
        public let pid: pid_t
        public let executablePath: String?
    }

    /// Reads the connected peer's effective credentials straight from the kernel.
    /// These cannot be forged by the peer, which is what makes them worth checking.
    public static func peerIdentity(of fd: Int32) throws -> PeerIdentity {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            throw SocketError.posix(errno, "getpeereid")
        }

        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        let gotPID = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0

        var path: String?
        if gotPID, pid > 0 {
            var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            if length > 0 {
                path = String(decoding: buffer[0..<Int(length)], as: UTF8.self)
            }
        }

        return PeerIdentity(uid: uid, gid: gid, pid: gotPID ? pid : -1, executablePath: path)
    }
}
