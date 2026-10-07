import Foundation

/// What the privileged server needs from a job implementation.
///
/// The server's responsibility is transport and authorisation; it has no reason
/// to know about disks. Inverting the dependency this way means the socket
/// protocol, the token check and the connection lifecycle can be tested against
/// a stub — without root, without a device, and without the risk that a test of
/// the handshake accidentally erases something.
public protocol JobRunning: Sendable {
    /// Runs `request` to completion.
    ///
    /// Contract the server relies on:
    /// - exactly one terminal frame (`jobFinished` or `jobFailed`) is emitted on
    ///   every path, including cancellation and unexpected failure;
    /// - ownership of `sourceDescriptor` transfers to the implementation, which
    ///   closes it;
    /// - `cancellation` is checked often enough that a request to stop takes
    ///   effect within a second or so.
    func execute(
        request: JobRequest,
        sourceDescriptor: Int32?,
        emit: @escaping @Sendable (HelperResponse) -> Void,
        cancellation: CancellationFlag
    ) async
}

/// What the server needs to report diagnostics, so that the executable can
/// decide where they go without the server depending on a concrete logger.
public protocol HelperDiagnostics: Sendable {
    func write(_ message: String)
    func error(_ message: String)
}

/// Diagnostics sink that discards everything. Used in tests.
public struct SilentDiagnostics: HelperDiagnostics {
    public init() {}
    public func write(_ message: String) {}
    public func error(_ message: String) {}
}
