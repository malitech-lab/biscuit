import Foundation

/// Byte formatting helpers. Deliberately uses decimal units for device
/// capacities (matching vendor labelling and Disk Utility) and binary units for
/// transfer buffers where precision matters.
public enum ByteCount {
    public static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    public static func formatRate(bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "–" }
        return "\(format(UInt64(bytesPerSecond)))/s"
    }

    public static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "–" }
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// Rounds `value` down to the nearest multiple of `alignment`.
    public static func alignDown(_ value: UInt64, to alignment: UInt64) -> UInt64 {
        guard alignment > 0 else { return value }
        return value - (value % alignment)
    }
}

public extension UInt64 {
    static func mebibytes(_ count: UInt64) -> UInt64 { count * 1024 * 1024 }
    static func gibibytes(_ count: UInt64) -> UInt64 { count * 1024 * 1024 * 1024 }
}
