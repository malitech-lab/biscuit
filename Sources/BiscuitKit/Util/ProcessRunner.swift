import Foundation

/// Launches external tools with argument-vector semantics (never a shell), so
/// that user-supplied strings such as volume labels or file paths can never be
/// reinterpreted as shell syntax.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let exitCode: Int32
        public let standardOutput: String
        public let standardError: String

        public var succeeded: Bool { exitCode == 0 }

        public var combinedOutput: String {
            [standardOutput, standardError]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let executable: String
        public let arguments: [String]
        public let result: Result

        public var description: String {
            "\(executable) \(arguments.joined(separator: " ")) → exit \(result.exitCode)\n\(result.combinedOutput)"
        }
    }

    /// Runs `executable` to completion, buffering both streams.
    ///
    /// - Parameter timeout: hard wall-clock limit. On expiry the child is sent
    ///   SIGTERM, then SIGKILL after a 2 s grace period.
    public static func run(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if standardInput != nil {
            inPipe = Pipe()
            process.standardInput = inPipe
        } else {
            inPipe = nil
            process.standardInput = FileHandle.nullDevice
        }

        let collector = StreamCollector()

        // Installed before launch so a child that exits immediately cannot be
        // missed.
        let waiter = TerminationWaiter()
        process.terminationHandler = { finished in
            waiter.complete(finished.terminationStatus)
        }

        try process.run()

        if let inPipe, let standardInput {
            try? inPipe.fileHandleForWriting.write(contentsOf: standardInput)
            try? inPipe.fileHandleForWriting.close()
        }

        // Drain both pipes concurrently; a child that fills a 64 KiB pipe buffer
        // while we wait on exit would otherwise deadlock.
        async let stdoutData = collector.drain(outPipe.fileHandleForReading)
        async let stderrData = collector.drain(errPipe.fileHandleForReading)

        let watchdog: Task<Void, Never>? = timeout.map { seconds in
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !Task.isCancelled, process.isRunning else { return }
                process.terminate()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }

        let out = await stdoutData
        let err = await stderrData
        let status = await waiter.value
        watchdog?.cancel()

        return Result(
            exitCode: status,
            standardOutput: String(decoding: out, as: UTF8.self),
            standardError: String(decoding: err, as: UTF8.self)
        )
    }

    /// Runs `executable` and throws `Failure` on a non-zero exit code.
    @discardableResult
    public static func runChecked(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Result {
        let result = try await run(
            executable,
            arguments: arguments,
            environment: environment,
            currentDirectory: currentDirectory,
            standardInput: standardInput,
            timeout: timeout
        )
        guard result.succeeded else {
            throw Failure(executable: executable, arguments: arguments, result: result)
        }
        return result
    }

    /// Streams both output streams line by line while the process runs. Used for
    /// tools that report progress incrementally.
    ///
    /// Both streams are observed deliberately: `wimlib-imagex` writes its
    /// progress to **stderr** and nothing to stdout, while other tools do the
    /// opposite. Watching only one would leave the progress bar frozen for the
    /// entire duration of a ten-minute operation — the single most likely reason
    /// a user would conclude the app had hung and pull the stick.
    ///
    /// - Returns: the exit status plus the complete text of both streams.
    public static func runStreaming(
        _ executable: String,
        arguments: [String],
        environment: [String: String]? = nil,
        onOutputLine: @escaping @Sendable (String) -> Void
    ) async throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let collector = StreamCollector()

        let waiter = TerminationWaiter()
        process.terminationHandler = { finished in
            waiter.complete(finished.terminationStatus)
        }

        try process.run()

        async let stdoutText = collector.drainLines(
            outPipe.fileHandleForReading,
            onLine: onOutputLine
        )
        async let stderrText = collector.drainLines(
            errPipe.fileHandleForReading,
            onLine: onOutputLine
        )

        let out = await stdoutText
        let err = await stderrText
        let status = await waiter.value

        return Result(
            exitCode: status,
            standardOutput: out,
            standardError: err
        )
    }

    /// Resolves an executable by probing a list of absolute candidate paths.
    /// We never consult `PATH`, because the helper runs as root and an attacker
    /// controlled `PATH` would be a privilege escalation.
    public static func locate(_ candidates: [String]) -> String? {
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}

/// Bridges `Process.terminationHandler` to `async`/`await`.
///
/// `Process.waitUntilExit()` must never be called from an `async` function. It
/// blocks the calling thread while spinning a run loop, and in an async context
/// that thread belongs to the Swift concurrency cooperative pool — which has
/// exactly `activeProcessorCount` threads.
///
/// The consequence is measurable rather than theoretical. With 24 concurrent
/// calls on an 8-core machine, every cooperative thread ends up parked inside
/// `waitUntilExit`, after which *no* `Task` can be scheduled at all. That
/// includes the timeout watchdog below: in a direct experiment, zero of 24
/// watchdogs fired within four times their deadline. A child that never exits
/// therefore cannot be terminated, and the operation hangs with no recovery
/// path and no diagnostic.
///
/// For this project that is a hang in the privileged helper, part-way through
/// erasing or writing a user's disk — the worst possible place to lose control.
/// Short commands such as `diskutil info` masked the problem completely, because
/// they exit before the blocking call is even reached.
///
/// `terminationHandler` fires on a Foundation-owned queue, so nothing blocks and
/// no run loop is involved.
private final class TerminationWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    /// Idempotent: only the first call resumes, so a double invocation of the
    /// termination handler cannot trap on a resumed continuation.
    func complete(_ newStatus: Int32) {
        lock.lock()
        guard status == nil else {
            lock.unlock()
            return
        }
        status = newStatus
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: newStatus)
    }

    var value: Int32 {
        get async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let status {
                    lock.unlock()
                    continuation.resume(returning: status)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        }
    }
}

/// Isolates the blocking pipe reads off the cooperative thread pool.
private actor StreamCollector {
    nonisolated func drain(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let data = (try? handle.readToEnd()) ?? Data()
                try? handle.close()
                continuation.resume(returning: data)
            }
        }
    }

    nonisolated func drainLines(
        _ handle: FileHandle,
        onLine: @escaping @Sendable (String) -> Void
    ) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var pending = Data()
                var complete = Data()
                while true {
                    guard let chunk = try? handle.read(upToCount: 16 * 1024),
                          !chunk.isEmpty else { break }
                    complete.append(chunk)
                    pending.append(chunk)
                    // Tools like createinstallmedia use \r for in-place updates.
                    while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let lineData = pending[pending.startIndex..<index]
                        pending.removeSubrange(pending.startIndex...index)
                        let line = String(decoding: lineData, as: UTF8.self)
                            .trimmingCharacters(in: .whitespaces)
                        if !line.isEmpty { onLine(line) }
                    }
                }
                if !pending.isEmpty {
                    let line = String(decoding: pending, as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { onLine(line) }
                }
                try? handle.close()
                continuation.resume(returning: String(decoding: complete, as: UTF8.self))
            }
        }
    }
}
