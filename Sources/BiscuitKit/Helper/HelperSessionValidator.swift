import Foundation

/// Validates the session directory and token before the privileged helper trusts
/// either.
///
/// These checks are the reason a local attacker cannot redirect the root process.
/// Without them, a pre-created symlink at the expected path would let an
/// unprivileged process choose which file root reads as the shared secret — and,
/// worse, decide where root creates its socket.
///
/// Separated from the executable's entry point so the rules are covered by tests
/// rather than only by inspection.
public enum HelperSessionValidator {
    public struct ValidationError: Error, Equatable, CustomStringConvertible {
        public enum Reason: Equatable, Sendable {
            case missing(String)
            case notADirectory(String)
            case notARegularFile(String)
            case wrongOwner(expected: uid_t, actual: uid_t)
            case wrongMode(expected: UInt16, actual: UInt16)
            case unreadable(String)
            case tokenTooShort(Int)
        }

        public let reason: Reason

        public init(_ reason: Reason) { self.reason = reason }

        public var description: String {
            switch reason {
            case .missing(let path):
                return "path not found: \(path)"
            case .notADirectory(let path):
                return "not a directory: \(path)"
            case .notARegularFile(let path):
                return "not a regular file: \(path)"
            case .wrongOwner(let expected, let actual):
                return "owned by uid \(actual), expected \(expected)"
            case .wrongMode(let expected, let actual):
                return String(format: "mode %o, expected %o", actual, expected)
            case .unreadable(let path):
                return "unreadable: \(path)"
            case .tokenTooShort(let count):
                return "token too short (\(count) characters)"
            }
        }
    }

    /// Base64 of 32 bytes is 44 characters. Anything materially shorter was not
    /// produced the way the app produces it.
    public static let minimumTokenLength = 40

    /// Verifies the session directory is a real, non-symlinked, 0700 directory
    /// owned by the user we were told to serve.
    ///
    /// `lstat` rather than `stat` on purpose: `stat` follows symlinks, which is
    /// exactly the substitution being guarded against.
    public static func validateSessionDirectory(
        at url: URL,
        expectedUID: uid_t
    ) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw ValidationError(.missing(url.path))
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw ValidationError(.notADirectory(url.path))
        }
        guard info.st_uid == expectedUID else {
            throw ValidationError(.wrongOwner(expected: expectedUID, actual: info.st_uid))
        }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions == 0o700 else {
            throw ValidationError(.wrongMode(expected: 0o700, actual: permissions))
        }
    }

    /// Reads the shared secret, enforcing the same ownership and mode rules.
    public static func readToken(at url: URL, expectedUID: uid_t) throws -> String {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw ValidationError(.missing(url.path))
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw ValidationError(.notARegularFile(url.path))
        }
        guard info.st_uid == expectedUID else {
            throw ValidationError(.wrongOwner(expected: expectedUID, actual: info.st_uid))
        }
        let permissions = UInt16(info.st_mode & 0o777)
        guard permissions == 0o600 else {
            throw ValidationError(.wrongMode(expected: 0o600, actual: permissions))
        }

        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ValidationError(.unreadable(url.path))
        }
        let token = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= minimumTokenLength else {
            throw ValidationError(.tokenTooShort(token.count))
        }
        return token
    }
}
