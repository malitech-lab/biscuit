import Foundation

/// Quoting for the few places where a command genuinely has to be assembled as
/// a single string rather than an argument vector: the AppleScript-mediated
/// privilege elevation, and the detached update swap script.
///
/// Everywhere else `ProcessRunner` passes `argv` directly, which needs no
/// quoting at all and is the only form that is safe by construction.
public enum ShellQuoting {
    /// Wraps a value in single quotes and escapes any embedded single quote by
    /// closing the quote, emitting an escaped quote, and reopening — the standard
    /// POSIX `sh` idiom. Inside single quotes `sh` performs no expansion, so no
    /// other character needs special treatment.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Joins an already-quoted argument list.
    public static func join(_ arguments: [String]) -> String {
        arguments.map(quote).joined(separator: " ")
    }
}
