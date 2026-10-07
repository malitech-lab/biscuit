import Foundation

/// Blocking, length-prefixed JSON frame transport over a socket file descriptor.
///
/// Thread model: `receive` must only ever be called from one thread at a time
/// (the owning read loop). `send` is serialised internally with a lock so that
/// a worker thread can push progress frames while the read loop is parked in
/// `recv`. This is the reason for the `@unchecked Sendable` conformance.
public final class FrameChannel: @unchecked Sendable {
    public enum ChannelError: Error, CustomStringConvertible {
        case closed
        case frameTooLarge(Int)
        case truncated
        case posix(Int32, String)
        case encoding(String)

        public var description: String {
            switch self {
            case .closed:
                return "connection closed"
            case .frameTooLarge(let size):
                return "frame too large (\(size) bytes)"
            case .truncated:
                return "truncated frame"
            case .posix(let code, let op):
                return "\(op): errno \(code) (\(String(cString: strerror(code))))"
            case .encoding(let detail):
                return "encoding error: \(detail)"
            }
        }
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private let encoder = IPCProtocol.makeEncoder()
    private let decoder = IPCProtocol.makeDecoder()
    private var isClosed = false
    private let closeLock = NSLock()

    public init(fileDescriptor: Int32) {
        SignalSetup.ignoreBrokenPipe()
        self.fd = fileDescriptor
        // Never let a broken pipe raise SIGPIPE; we want EPIPE from write(2).
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        close()
    }

    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, SHUT_RDWR)
        _ = Darwin.close(fd)
    }

    public var closed: Bool {
        closeLock.lock()
        defer { closeLock.unlock() }
        return isClosed
    }

    // MARK: - Sending

    public func send<T: Encodable>(_ value: T) throws {
        let payload: Data
        do {
            payload = try encoder.encode(value)
        } catch {
            throw ChannelError.encoding(String(describing: error))
        }
        guard payload.count <= IPCProtocol.maxFrameBytes else {
            throw ChannelError.frameTooLarge(payload.count)
        }

        var header = UInt32(payload.count).bigEndian
        var frame = Data(count: 4)
        withUnsafeBytes(of: &header) { bytes in
            frame.replaceSubrange(0..<4, with: bytes)
        }
        frame.append(payload)

        writeLock.lock()
        defer { writeLock.unlock() }
        try writeAll(frame)
    }

    /// Sends `value` and then, atomically with respect to other senders, the
    /// `SCM_RIGHTS` ancillary message carrying `descriptor`.
    ///
    /// Both halves must be contiguous on the wire: the receiver reads the frame
    /// and then immediately performs the matching `recvmsg`, so another sender
    /// slipping a frame in between would misalign the stream. Holding the write
    /// lock across both operations is what makes that impossible.
    public func send<T: Encodable>(_ value: T, withDescriptor descriptor: Int32) throws {
        let payload: Data
        do {
            payload = try encoder.encode(value)
        } catch {
            throw ChannelError.encoding(String(describing: error))
        }
        guard payload.count <= IPCProtocol.maxFrameBytes else {
            throw ChannelError.frameTooLarge(payload.count)
        }

        var header = UInt32(payload.count).bigEndian
        var frame = Data(count: 4)
        withUnsafeBytes(of: &header) { bytes in
            frame.replaceSubrange(0..<4, with: bytes)
        }
        frame.append(payload)

        writeLock.lock()
        defer { writeLock.unlock() }
        try writeAll(frame)
        try DescriptorTransfer.send(descriptor: descriptor, over: fd)
    }

    private func writeAll(_ data: Data) throws {
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let written = Darwin.send(fd, base.advanced(by: offset), data.count - offset, 0)
                if written > 0 {
                    offset += written
                    continue
                }
                if written == 0 { throw ChannelError.closed }
                let err = errno
                if err == EINTR { continue }
                if err == EPIPE || err == ECONNRESET { throw ChannelError.closed }
                throw ChannelError.posix(err, "send")
            }
        }
    }

    // MARK: - Receiving

    /// Returns `nil` on a clean EOF from the peer.
    public func receive<T: Decodable>(_ type: T.Type) throws -> T? {
        guard let header = try readExactly(4) else { return nil }
        let length = header.withUnsafeBytes { raw in
            UInt32(bigEndian: raw.loadUnaligned(as: UInt32.self))
        }
        guard length > 0 else { throw ChannelError.truncated }
        guard length <= UInt32(IPCProtocol.maxFrameBytes) else {
            throw ChannelError.frameTooLarge(Int(length))
        }
        guard let payload = try readExactly(Int(length)) else {
            throw ChannelError.truncated
        }
        do {
            return try decoder.decode(T.self, from: payload)
        } catch {
            throw ChannelError.encoding(String(describing: error))
        }
    }

    /// Returns `nil` only when zero bytes were read before EOF.
    private func readExactly(_ count: Int) throws -> Data? {
        var buffer = Data(count: count)
        var offset = 0
        while offset < count {
            let read: Int = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.recv(fd, base.advanced(by: offset), count - offset, 0)
            }
            if read > 0 {
                offset += read
                continue
            }
            if read == 0 {
                if offset == 0 { return nil }
                throw ChannelError.truncated
            }
            let err = errno
            if err == EINTR { continue }
            if err == ECONNRESET || err == EPIPE {
                if offset == 0 { return nil }
                throw ChannelError.truncated
            }
            throw ChannelError.posix(err, "recv")
        }
        return buffer
    }
}
