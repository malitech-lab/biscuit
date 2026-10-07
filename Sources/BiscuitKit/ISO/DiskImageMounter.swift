import Foundation

/// Attaches disk images read-only via `hdiutil`, with guaranteed detach.
///
/// Read-only attach does not require elevated privileges, so inspection happens
/// entirely in the unprivileged app process.
public struct DiskImageMounter: Sendable {
    public static let hdiutil = "/usr/bin/hdiutil"

    public struct Attachment: Sendable {
        /// `/dev/diskN` entries created by the attach.
        public let devEntries: [String]
        public let mountPoint: URL?
        /// Entry to hand back to `hdiutil detach`; the whole-disk node.
        public let detachTarget: String
    }

    public init() {}

    public func attachReadOnly(_ imageURL: URL) async throws -> Attachment {
        let result = try await ProcessRunner.run(
            Self.hdiutil,
            arguments: [
                "attach",
                imageURL.path,
                "-plist",
                "-nobrowse",
                "-readonly",
                "-noverify",
                "-noautoopen",
                "-noautofsck"
            ],
            timeout: 180
        )

        guard result.succeeded else {
            throw BiscuitError(
                kind: .mountFailed,
                message: t(.errorMountFailed),
                remedy: t(.errorMountFailedRemedy),
                diagnostics: result.combinedOutput
            )
        }

        guard let plistData = result.standardOutput.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: plistData, options: [], format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else {
            throw BiscuitError(
                kind: .mountFailed,
                message: t(.errorMountFailed),
                diagnostics: result.standardOutput
            )
        }

        var devEntries: [String] = []
        var mountPoint: URL?
        for entity in entities {
            if let dev = entity["dev-entry"] as? String { devEntries.append(dev) }
            if mountPoint == nil, let path = entity["mount-point"] as? String, !path.isEmpty {
                mountPoint = URL(fileURLWithPath: path)
            }
        }

        // The shortest dev entry is the whole-disk node (e.g. /dev/disk5 vs
        // /dev/disk5s1); detaching that releases every slice at once.
        guard let whole = devEntries.min(by: { $0.count < $1.count }) else {
            throw BiscuitError(
                kind: .mountFailed,
                message: t(.errorMountFailed),
                diagnostics: result.standardOutput
            )
        }

        return Attachment(devEntries: devEntries, mountPoint: mountPoint, detachTarget: whole)
    }

    public func detach(_ attachment: Attachment) async {
        // Try graceful first, then force. A failed detach would leave a stale
        // device node behind, so this never throws — it escalates instead.
        let graceful = try? await ProcessRunner.run(
            Self.hdiutil,
            arguments: ["detach", attachment.detachTarget],
            timeout: 60
        )
        if graceful?.succeeded == true { return }
        _ = try? await ProcessRunner.run(
            Self.hdiutil,
            arguments: ["detach", attachment.detachTarget, "-force"],
            timeout: 60
        )
    }

    /// Attaches, runs `body`, and always detaches — including on cancellation.
    public func withReadOnlyMount<T>(
        _ imageURL: URL,
        _ body: (Attachment) async throws -> T
    ) async throws -> T {
        let attachment = try await attachReadOnly(imageURL)
        do {
            let value = try await body(attachment)
            await detach(attachment)
            return value
        } catch {
            await detach(attachment)
            throw error
        }
    }
}
