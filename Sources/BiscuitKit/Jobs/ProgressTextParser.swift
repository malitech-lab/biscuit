import Foundation

/// Extracts a completion percentage from the progress chatter of external tools.
///
/// Two tools matter here and neither offers a machine-readable channel:
///
///     wimlib-imagex   Splitting WIM: 6 MiB of 18 MiB (33%) written, part 1 of 3
///     wimlib-imagex   Writing LZX-compressed data using 10 threads: 42% done
///     createinstallmedia  Copying to disk: 34% complete
///
/// Parsing human-readable output is inherently brittle, so it is isolated here
/// and covered directly by tests against recorded real output, rather than only
/// being exercised indirectly through a subprocess.
public enum ProgressTextParser {
    /// Returns the last percentage mentioned in `line`, or nil.
    ///
    /// The *last* occurrence is used deliberately: wimlib's split output ends in
    /// "part 1 of 3", and an earlier-match strategy on a line such as
    /// "50% done, 2 of 3" would still work, but taking the last `%` is robust
    /// against a tool prefixing its line with an unrelated figure.
    public static func percentage(in line: String) -> Double? {
        guard let percentIndex = line.lastIndex(of: "%") else { return nil }

        var digits = ""
        var index = percentIndex
        while index > line.startIndex {
            index = line.index(before: index)
            let character = line[index]
            if character.isNumber || character == "." || character == "," {
                digits.append(character == "," ? "." : character)
            } else {
                break
            }
        }
        guard !digits.isEmpty else { return nil }

        let value = Double(String(digits.reversed()))
        guard let value, value.isFinite, value >= 0, value <= 100 else { return nil }
        return value
    }
}

/// Turns a stream of tool output lines into throttled, monotonic progress
/// reports.
///
/// Monotonic because a bar that jumps backwards reads as a malfunction, and
/// deduplicated because the tools repeat the same percentage dozens of times —
/// letting a repeat consume the throttle budget is what makes a short operation
/// report no progress at all.
public final class ToolProgressReporter: @unchecked Sendable {
    private let context: JobContext
    private let phase: JobPhase
    private let fractionRange: ClosedRange<Double>
    private let lock = NSLock()
    private var throttle: ProgressThrottle
    private var lastPercent: Double = -1
    private var sawAny = false

    public init(
        context: JobContext,
        phase: JobPhase,
        fractionRange: ClosedRange<Double> = 0...1,
        minimumInterval: TimeInterval = 0.05
    ) {
        self.context = context
        self.phase = phase
        self.fractionRange = fractionRange
        self.throttle = ProgressThrottle(minimumInterval: minimumInterval)
    }

    /// Feeds one output line. Lines without a percentage are forwarded to the
    /// log at debug level instead, so a tool's status messages are not lost.
    public func consume(_ line: String) {
        guard let percent = ProgressTextParser.percentage(in: line) else {
            if line.count > 3 { context.log(.debug, line) }
            return
        }

        lock.lock()
        // Ignore a percentage that does not advance: it carries no information
        // and would otherwise exhaust the throttle interval.
        guard percent > lastPercent else {
            lock.unlock()
            return
        }
        lastPercent = percent
        let shouldEmit = throttle.shouldEmit(force: !sawAny || percent >= 100)
        sawAny = true
        lock.unlock()

        guard shouldEmit else { return }

        let span = fractionRange.upperBound - fractionRange.lowerBound
        let scaled = fractionRange.lowerBound + (percent / 100) * span
        context.report(
            phase: phase,
            phaseFraction: scaled.clamped(to: 0...1),
            detail: line
        )
    }

    /// Highest percentage observed, for assertions and for a final report.
    public var highestPercent: Double? {
        lock.lock(); defer { lock.unlock() }
        return lastPercent >= 0 ? lastPercent : nil
    }
}
