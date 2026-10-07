import Foundation

/// Passes an open file descriptor across the privilege boundary using
/// `SCM_RIGHTS` ancillary data on the existing AF_UNIX socket.
///
/// This exists to solve a problem that is easy to miss until it bites: macOS
/// privacy protection (TCC) guards `~/Downloads`, `~/Documents`, `~/Desktop`,
/// iCloud Drive and network volumes, and **running as root does not exempt a
/// process from it**. Which process is held "responsible" for a daemon spawned
/// through an authorisation dialog has also changed between macOS releases.
///
/// So the helper never opens the user's image by path. The app — which already
/// holds a TCC grant for the file, implicitly given when the user picked it in
/// the open panel — opens it and hands the descriptor over. The kernel copies
/// the open file reference into the receiving process, access checks and all
/// already performed.
///
/// A useful side effect: the source cannot be swapped between validation and
/// writing, because the descriptor refers to the inode, not the name.
public enum DescriptorTransfer {
    public enum TransferError: Error, CustomStringConvertible {
        case posix(Int32, String)
        case noDescriptorReceived
        case unexpectedPayload(Int)

        public var description: String {
            switch self {
            case .posix(let code, let op):
                return "\(op): errno \(code) (\(String(cString: strerror(code))))"
            case .noDescriptorReceived:
                return "peer sent no file descriptor"
            case .unexpectedPayload(let count):
                return "unexpected payload (\(count) bytes)"
            }
        }
    }

    /// One byte of real payload is required: `sendmsg` with an empty iovec may
    /// legally discard the ancillary data.
    private static let payloadByte: UInt8 = 0x2A

    /// Sends `descriptor` over `socket`.
    public static func send(descriptor: Int32, over socket: Int32) throws {
        var payload = payloadByte
        try withUnsafeMutableBytes(of: &payload) { payloadBuffer in
            var iov = iovec(
                iov_base: payloadBuffer.baseAddress,
                iov_len: payloadBuffer.count
            )

            // cmsghdr must be allocated with CMSG_SPACE alignment, hence the
            // manual buffer rather than a Swift struct.
            let controlLength = Int(cmsgSpace(MemoryLayout<Int32>.size))
            let control = UnsafeMutableRawPointer.allocate(
                byteCount: controlLength,
                alignment: MemoryLayout<cmsghdr>.alignment
            )
            defer { control.deallocate() }
            memset(control, 0, controlLength)

            var message = msghdr()
            try withUnsafeMutablePointer(to: &iov) { iovPointer in
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlLength)

                let header = control.assumingMemoryBound(to: cmsghdr.self)
                header.pointee.cmsg_len = socklen_t(cmsgLen(MemoryLayout<Int32>.size))
                header.pointee.cmsg_level = SOL_SOCKET
                header.pointee.cmsg_type = SCM_RIGHTS
                cmsgData(header).assumingMemoryBound(to: Int32.self).pointee = descriptor

                while sendmsg(socket, &message, 0) < 0 {
                    if errno == EINTR { continue }
                    throw TransferError.posix(errno, "sendmsg")
                }
            }
        }
    }

    /// Receives a descriptor sent by `send`. The returned descriptor is owned by
    /// the caller and must be closed.
    public static func receive(from socket: Int32) throws -> Int32 {
        var payload: UInt8 = 0
        return try withUnsafeMutableBytes(of: &payload) { payloadBuffer -> Int32 in
            var iov = iovec(
                iov_base: payloadBuffer.baseAddress,
                iov_len: payloadBuffer.count
            )

            let controlLength = Int(cmsgSpace(MemoryLayout<Int32>.size))
            let control = UnsafeMutableRawPointer.allocate(
                byteCount: controlLength,
                alignment: MemoryLayout<cmsghdr>.alignment
            )
            defer { control.deallocate() }
            memset(control, 0, controlLength)

            var message = msghdr()
            return try withUnsafeMutablePointer(to: &iov) { iovPointer -> Int32 in
                message.msg_iov = iovPointer
                message.msg_iovlen = 1
                message.msg_control = control
                message.msg_controllen = socklen_t(controlLength)

                var received = 0
                while true {
                    received = recvmsg(socket, &message, 0)
                    if received >= 0 { break }
                    if errno == EINTR { continue }
                    throw TransferError.posix(errno, "recvmsg")
                }
                guard received == 1 else {
                    throw TransferError.unexpectedPayload(received)
                }

                guard let header = firstHeader(of: &message),
                      header.pointee.cmsg_level == SOL_SOCKET,
                      header.pointee.cmsg_type == SCM_RIGHTS,
                      header.pointee.cmsg_len >= socklen_t(cmsgLen(MemoryLayout<Int32>.size))
                else {
                    throw TransferError.noDescriptorReceived
                }

                let descriptor = cmsgData(header)
                    .assumingMemoryBound(to: Int32.self)
                    .pointee
                guard descriptor >= 0 else { throw TransferError.noDescriptorReceived }
                return descriptor
            }
        }
    }

    // MARK: - CMSG macros
    //
    // `CMSG_SPACE`, `CMSG_LEN`, `CMSG_DATA` and `CMSG_FIRSTHDR` are C macros and
    // are therefore not imported into Swift. These reimplement them exactly as
    // defined in `<sys/socket.h>` on Darwin.

    private static func alignCMSG(_ length: Int) -> Int {
        let alignment = MemoryLayout<UInt32>.size
        return (length + alignment - 1) & ~(alignment - 1)
    }

    private static func cmsgSpace(_ payload: Int) -> Int {
        alignCMSG(MemoryLayout<cmsghdr>.size) + alignCMSG(payload)
    }

    private static func cmsgLen(_ payload: Int) -> Int {
        alignCMSG(MemoryLayout<cmsghdr>.size) + payload
    }

    private static func cmsgData(_ header: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(header)
            .advanced(by: alignCMSG(MemoryLayout<cmsghdr>.size))
    }

    private static func firstHeader(
        of message: inout msghdr
    ) -> UnsafeMutablePointer<cmsghdr>? {
        guard message.msg_controllen >= socklen_t(MemoryLayout<cmsghdr>.size),
              let control = message.msg_control
        else { return nil }
        return control.assumingMemoryBound(to: cmsghdr.self)
    }
}
