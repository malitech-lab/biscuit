import Foundation

/// Cooperative cancellation flag shared between the IPC read loop (which may
/// receive a `cancelJob`) and the worker performing the write.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isSet: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func set() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        cancelled = false
    }

    /// Throws `BiscuitError.cancelled` if a cancellation was requested.
    public func check() throws {
        if isSet { throw BiscuitError.cancelled }
    }
}

/// Everything an operation needs to report back to the app, plus the phase
/// weighting used to turn per-phase progress into a single overall figure.
public struct JobContext: Sendable {
    public let request: JobRequest
    public let phases: [JobPhase]
    private let emit: @Sendable (HelperResponse) -> Void
    public let cancellation: CancellationFlag

    public init(
        request: JobRequest,
        phases: [JobPhase],
        cancellation: CancellationFlag,
        emit: @escaping @Sendable (HelperResponse) -> Void
    ) {
        self.request = request
        self.phases = phases
        self.cancellation = cancellation
        self.emit = emit
    }

    // MARK: - Phase weighting

    /// Relative cost of each phase. Writing and verifying dominate; the rest are
    /// near-instant but still deserve a visible slice so the bar never stalls.
    private static func weight(of phase: JobPhase) -> Double {
        switch phase {
        case .preparing: return 1
        case .unmounting: return 1
        case .partitioning: return 4
        case .mounting: return 1
        case .writing: return 100
        case .copying: return 100
        case .splittingWIM: return 40
        case .flushing: return 6
        case .verifying: return 60
        case .finalising: return 2
        case .done: return 0
        }
    }

    private var totalWeight: Double {
        phases.reduce(0) { $0 + Self.weight(of: $1) }
    }

    private func weightBefore(_ phase: JobPhase) -> Double {
        guard let index = phases.firstIndex(of: phase) else { return 0 }
        return phases[..<index].reduce(0) { $0 + Self.weight(of: $1) }
    }

    public func overallFraction(phase: JobPhase, phaseFraction: Double?) -> Double? {
        let total = totalWeight
        guard total > 0 else { return nil }
        let before = weightBefore(phase)
        let current = Self.weight(of: phase)
        let within = (phaseFraction ?? 0).clamped(to: 0...1)
        return ((before + current * within) / total).clamped(to: 0...1)
    }

    // MARK: - Reporting

    public func report(
        phase: JobPhase,
        phaseFraction: Double? = nil,
        bytesProcessed: UInt64 = 0,
        bytesTotal: UInt64? = nil,
        bytesPerSecond: Double? = nil,
        secondsRemaining: Double? = nil,
        detail: String? = nil
    ) {
        emit(.progress(JobProgress(
            jobID: request.id,
            phase: phase,
            phaseFraction: phaseFraction,
            overallFraction: overallFraction(phase: phase, phaseFraction: phaseFraction),
            bytesProcessed: bytesProcessed,
            bytesTotal: bytesTotal,
            bytesPerSecond: bytesPerSecond,
            secondsRemaining: secondsRemaining,
            detail: detail
        )))
    }

    public func log(_ level: LogLevel, _ message: String) {
        emit(.log(LogEntry(level: level, source: "helper", message: message)))
    }
}

extension Comparable {
    public func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

/// Throttles progress emission so a fast NVMe-backed write does not flood the
/// socket with tens of thousands of frames per second.
public struct ProgressThrottle: Sendable {
    private let minimumInterval: TimeInterval
    private var lastEmit: Date = .distantPast

    public init(minimumInterval: TimeInterval = 0.1) {
        self.minimumInterval = minimumInterval
    }

    public mutating func shouldEmit(force: Bool = false) -> Bool {
        let now = Date()
        if force || now.timeIntervalSince(lastEmit) >= minimumInterval {
            lastEmit = now
            return true
        }
        return false
    }
}

/// Exponentially smoothed throughput estimator, so the ETA does not jitter
/// wildly when the device's write cache fills and drains.
public struct ThroughputEstimator: Sendable {
    private let smoothing: Double
    private var averageBytesPerSecond: Double?
    private var lastSample: (date: Date, bytes: UInt64)?

    public init(smoothing: Double = 0.2) {
        self.smoothing = smoothing
    }

    public mutating func update(bytes: UInt64, now: Date = Date()) -> Double? {
        defer { lastSample = (now, bytes) }
        guard let previous = lastSample else { return nil }
        let elapsed = now.timeIntervalSince(previous.date)
        guard elapsed > 0.05, bytes >= previous.bytes else { return averageBytesPerSecond }
        let instant = Double(bytes - previous.bytes) / elapsed
        if let current = averageBytesPerSecond {
            averageBytesPerSecond = current + smoothing * (instant - current)
        } else {
            averageBytesPerSecond = instant
        }
        return averageBytesPerSecond
    }

    public var rate: Double? { averageBytesPerSecond }

    public func secondsRemaining(processed: UInt64, total: UInt64?) -> Double? {
        guard let total, total > processed, let rate = averageBytesPerSecond, rate > 0 else {
            return nil
        }
        return Double(total - processed) / rate
    }
}
