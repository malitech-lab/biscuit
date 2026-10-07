import Foundation

/// How the privileged helper reaches the job's input data.
///
/// The helper is deliberately never given a path it has to open inside the
/// user's home directory. macOS privacy protection (TCC) guards `~/Downloads`,
/// `~/Documents`, `~/Desktop`, iCloud Drive and network mounts, and a root
/// process is *not* exempt — so an implementation that passes
/// `/Users/x/Downloads/win11.iso` to a root daemon works on one macOS release
/// and returns `EPERM` on the next.
///
/// Instead:
/// - raw images arrive as an already-open descriptor (`SCM_RIGHTS`);
/// - ISO contents arrive as a mount point under `/Volumes`, attached read-only
///   by the unprivileged app, which TCC does not restrict;
/// - the only path the helper opens itself is an installer bundle in
///   `/Applications`, which is outside TCC's scope by design.
public enum SourceHandle: Codable, Sendable, Hashable {
    /// No input (erase-only jobs).
    case none

    /// A descriptor the app transfers over the socket immediately before the
    /// job request. `sizeBytes` is authoritative for progress reporting;
    /// `displayName` is for logging only.
    case transferredDescriptor(sizeBytes: UInt64, displayName: String)

    /// A directory the app has already made readable, typically an ISO attached
    /// read-only under `/Volumes`.
    case mountedDirectory(path: String, displayName: String)

    /// An application bundle outside TCC scope, e.g.
    /// `/Applications/Install macOS Sequoia.app`.
    case applicationBundle(path: String)

    public var requiresDescriptorTransfer: Bool {
        if case .transferredDescriptor = self { return true }
        return false
    }

    public var displayName: String {
        switch self {
        case .none:
            return "–"
        case .transferredDescriptor(_, let name):
            return name
        case .mountedDirectory(_, let name):
            return name
        case .applicationBundle(let path):
            return (path as NSString).lastPathComponent
        }
    }

    public var sizeBytes: UInt64? {
        if case .transferredDescriptor(let size, _) = self { return size }
        return nil
    }

    /// Paths the helper may open. Validated by the helper before use.
    public var localPath: String? {
        switch self {
        case .none, .transferredDescriptor:
            return nil
        case .mountedDirectory(let path, _):
            return path
        case .applicationBundle(let path):
            return path
        }
    }

    /// Prefixes the helper will accept for a path-based handle.
    ///
    /// Anything else is refused outright, which turns "the app asked root to
    /// read an arbitrary path" from a design assumption into an enforced
    /// invariant. The app is not a trusted peer merely because it holds the
    /// session token.
    public static let allowedPathPrefixes = [
        "/Volumes/",
        "/Applications/",
        "/private/var/tmp/biscuit-",
        "/System/Volumes/Data/Volumes/"
    ]

    public func validatePath() throws {
        guard let path = localPath else { return }
        let standardised = (path as NSString).standardizingPath
        guard Self.allowedPathPrefixes.contains(where: { standardised.hasPrefix($0) }) else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorSourcePathNotAllowed),
                remedy: t(.errorSourcePathNotAllowedRemedy),
                diagnostics: standardised
            )
        }
        // Reject traversal attempts that survive standardisation.
        guard !standardised.contains("/../") else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorSourcePathInvalid),
                diagnostics: standardised
            )
        }
    }
}
