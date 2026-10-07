import BiscuitKit
import Foundation
import Security

/// Obtains root for the duration of one app session and launches the helper.
///
/// Design rationale: a persistent `SMAppService` LaunchDaemon would need a
/// stable Developer ID team identifier to express a code-signing requirement,
/// which this project deliberately does not depend on. The session-scoped model
/// used here mirrors what Rufus does on Windows — elevate once per launch, keep
/// nothing installed — and has a strictly smaller attack surface than an
/// always-resident root daemon.
///
/// Flow:
/// 1. Create a 0700 session directory under the user's Application Support.
/// 2. Write a 32-byte random token to a 0600 file inside it.
/// 3. Ask macOS for admin rights and use them to spawn the helper detached.
/// 4. Connect to the socket the helper binds, present the token, handshake.
@MainActor
final class PrivilegeBroker {
    private let appSupport: URL
    private let helperExecutable: URL
    private let clientBundlePrefix: String?
    private let clientVersion: String

    private var session: ActiveSession?

    private struct ActiveSession {
        let paths: HelperSessionPaths
        let client: HelperClient
    }

    init(
        appSupport: URL,
        helperExecutable: URL,
        clientBundlePrefix: String?,
        clientVersion: String
    ) {
        self.appSupport = appSupport
        self.helperExecutable = helperExecutable
        self.clientBundlePrefix = clientBundlePrefix
        self.clientVersion = clientVersion
    }

    // MARK: - Public API

    var isConnected: Bool {
        guard let session else { return false }
        return session.client.isAlive
    }

    /// Returns a live, authenticated client, elevating first if necessary.
    func client() async throws -> HelperClient {
        if let session, session.client.isAlive { return session.client }
        if session != nil { await teardown() }
        return try await establish()
    }

    func teardown() async {
        guard let session else { return }
        self.session = nil
        await session.client.shutdown()
        try? FileManager.default.removeItem(at: session.paths.root)
    }

    // MARK: - Establishing a session

    private func establish() async throws -> HelperClient {
        try verifyHelperBinary()

        let paths = try prepareSessionDirectory()
        let token = try Self.makeToken()
        try writeToken(token, to: paths.token)

        guard paths.socketPathFitsInSunPath else {
            throw BiscuitError.helperUnavailable(
                "socket path too long: \(paths.socket.path)"
            )
        }

        do {
            try await launchElevatedHelper(paths: paths)
            let client = try await HelperClient.connect(
                socketPath: paths.socket.path,
                token: token,
                clientVersion: clientVersion
            )
            session = ActiveSession(paths: paths, client: client)
            return client
        } catch {
            try? FileManager.default.removeItem(at: paths.root)
            throw error
        }
    }

    /// Refuses to run a helper that a non-admin process could have replaced.
    /// Launching a group- or world-writable binary as root would be a trivial
    /// privilege escalation.
    private func verifyHelperBinary() throws {
        let path = helperExecutable.path
        var info = stat()
        guard lstat(path, &info) == 0 else {
            throw BiscuitError.helperUnavailable("helper not found: \(path)")
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw BiscuitError.helperUnavailable("helper is not a regular file: \(path)")
        }
        guard (info.st_mode & S_IXUSR) != 0 else {
            throw BiscuitError.helperUnavailable("helper is not executable: \(path)")
        }
        let writableByOthers = (info.st_mode & (S_IWGRP | S_IWOTH)) != 0
        guard !writableByOthers else {
            throw BiscuitError(
                kind: .helperUnavailable,
                message: t(.errorHelperWorldWritable),
                remedy: t(.errorHelperWorldWritableRemedy),
                diagnostics: String(format: "%@ hat Modus %o", path, info.st_mode & 0o777)
            )
        }
    }

    private func prepareSessionDirectory() throws -> HelperSessionPaths {
        let paths = HelperSessionPaths.makeUnique(appSupport: appSupport)
        let fm = FileManager.default
        // Remove any pre-existing node so a planted symlink cannot redirect us.
        try? fm.removeItem(at: paths.root)
        try fm.createDirectory(
            at: paths.root.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fm.createDirectory(
            at: paths.root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return paths
    }

    /// 32 bytes from the kernel CSPRNG, base64 encoded for safe transport as a
    /// JSON string. `Int.random` and friends are explicitly not used here.
    private static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: IPCProtocol.tokenByteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BiscuitError.helperUnavailable(
                "SecRandomCopyBytes failed: \(status)"
            )
        }
        return Data(bytes).base64EncodedString()
    }

    private func writeToken(_ token: String, to url: URL) throws {
        let data = Data(token.utf8)
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        guard fm.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw BiscuitError.helperUnavailable(t(.errorTokenWriteFailed))
        }
    }

    // MARK: - Elevation

    /// Spawns the helper as root, detached, via the system authorisation dialog.
    ///
    /// `osascript` is used rather than the deprecated
    /// `AuthorizationExecuteWithPrivileges`, which Apple has been threatening to
    /// remove for a decade and which cannot present a custom prompt. The command
    /// is passed through `argv` instead of being interpolated into the AppleScript
    /// source, so there is no second layer of quoting to get wrong.
    private func launchElevatedHelper(paths: HelperSessionPaths) async throws {
        let uid = getuid()
        var parts = [
            ShellQuoting.quote(helperExecutable.path),
            "--session", ShellQuoting.quote(paths.root.path),
            "--uid", String(uid)
        ]
        if let clientBundlePrefix {
            parts.append("--client-prefix")
            parts.append(ShellQuoting.quote(clientBundlePrefix))
        }
        // Detach so `do shell script` returns instead of blocking until the
        // helper exits. Output is discarded; the helper writes its own log.
        parts.append(">/dev/null 2>&1 &")
        let command = parts.joined(separator: " ")

        let prompt = t(.privilegePrompt)

        let result = try await ProcessRunner.run(
            "/usr/bin/osascript",
            arguments: [
                "-e", "on run argv",
                "-e", "do shell script (item 1 of argv) with prompt (item 2 of argv) with administrator privileges",
                "-e", "end run",
                command,
                prompt
            ],
            timeout: 300
        )

        guard result.succeeded else {
            let output = result.combinedOutput
            // -128 is the documented "user cancelled" AppleEvent error.
            if output.contains("-128") || output.lowercased().contains("cancel") {
                throw BiscuitError.privilegeDenied(output)
            }
            throw BiscuitError.helperUnavailable(
                "osascript exit \(result.exitCode): \(output)"
            )
        }
    }

}
