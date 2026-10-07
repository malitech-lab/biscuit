import Foundation

/// Process-wide signal disposition that every Biscuit process needs.
public enum SignalSetup {
    /// Disables SIGPIPE once, so a broken pipe surfaces as `EPIPE` from
    /// `write(2)` instead of killing the process.
    ///
    /// `biscuit-helper` has always done this in `main.swift`, with the right
    /// reasoning: a peer that disappears must not be able to terminate a
    /// process that is part-way through writing a disk. The app and the test
    /// process never did, and `FrameChannel`'s `SO_NOSIGPIPE` only covers
    /// sockets — not the pipes `ProcessRunner` uses to talk to child
    /// processes, where that option does not apply.
    ///
    /// The immediate cause was a release build whose test step died with
    /// signal 13 while several process-spawning tests were in flight. The exact
    /// write was not identified, and this is deliberately not presented as a
    /// proven fix for it: it removes a failure mode that should not exist in
    /// any case, in a process that writes to pipes and sockets it does not
    /// control.
    ///
    /// Idempotent and safe to call from anywhere, including concurrently.
    public static func ignoreBrokenPipe() {
        _ = sigpipeIgnored
    }

    private static let sigpipeIgnored: Bool = {
        signal(SIGPIPE, SIG_IGN)
        return true
    }()
}
