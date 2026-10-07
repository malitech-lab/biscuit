import Foundation
import os

/// Append-only diagnostic log for the privileged process.
///
/// Everything also goes to the unified log under the `helper` category, which is
/// what you want when the helper dies before it can talk to the app. The file
/// copy exists because `log stream` requires the user to already suspect a
/// problem, whereas a path the app can read lets the GUI surface the failure.
enum HelperLog {
    private static let subsystem = "dev.biscuit.helper"
    private static let logger = Logger(subsystem: subsystem, category: "helper")
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fileHandle: FileHandle?
    nonisolated(unsafe) private static var destination: URL?
    /// Only ever touched while `lock` is held.
    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Redirects file output to `url`, creating it 0600 so only root and the
    /// owning user can read the diagnostics.
    static func configure(path url: URL) {
        lock.lock()
        defer { lock.unlock() }
        destination = url
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600]
            )
        }
        fileHandle = try? FileHandle(forWritingTo: url)
        _ = try? fileHandle?.seekToEnd()
    }

    static func write(_ message: String) {
        logger.log("\(message, privacy: .public)")

        lock.lock()
        defer { lock.unlock() }
        guard let fileHandle else { return }
        let stamp = timestampFormatter.string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        try? fileHandle.write(contentsOf: Data(line.utf8))
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        write("ERROR \(message)")
    }
}
