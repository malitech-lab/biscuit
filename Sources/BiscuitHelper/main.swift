import BiscuitKit
import Foundation

/// Entry point for the privileged helper.
///
/// Invoked as root by the app after the user grants admin authorisation. All
/// parameters arrive as arguments rather than environment variables, because an
/// inherited environment is attacker-influenced and this process runs as root.
///
///     biscuit-helper --session <dir> --uid <n> [--client-prefix <path>]
///
/// The session directory must already exist, be owned by `--uid`, and contain a
/// 0600 token file. The helper refuses to start otherwise.
///
/// Deliberately thin: argument parsing, the root check, and wiring. Everything
/// testable lives in `BiscuitKit`.

struct HelperArguments {
    var sessionDirectory: URL
    var clientUID: uid_t
    var clientPrefix: String?

    static func parse(_ arguments: [String]) throws -> HelperArguments {
        var session: String?
        var uid: uid_t?
        var prefix: String?

        var index = 1
        while index < arguments.count {
            let flag = arguments[index]
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            switch flag {
            case "--session":
                session = value
                index += 2
            case "--uid":
                uid = value.flatMap { UInt32($0) }
                index += 2
            case "--client-prefix":
                prefix = value
                index += 2
            case "--version":
                print(HelperVersion.current)
                exit(0)
            default:
                throw StartupError("unknown argument: \(flag)")
            }
        }

        guard let session else { throw StartupError("--session is required") }
        guard let uid else { throw StartupError("--uid is required") }
        // Serving root would mean the token check protects nothing.
        guard uid != 0 else { throw StartupError("--uid must not be 0") }

        return HelperArguments(
            sessionDirectory: URL(fileURLWithPath: session, isDirectory: true),
            clientUID: uid,
            clientPrefix: prefix
        )
    }
}

struct StartupError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum HelperVersion {
    static let current = "1.0.0"
}

/// Bridges the server's diagnostics protocol to the file + unified log.
struct FileDiagnostics: HelperDiagnostics {
    func write(_ message: String) { HelperLog.write(message) }
    func error(_ message: String) { HelperLog.error(message) }
}

func bootstrap() -> Int32 {
    let arguments: HelperArguments
    do {
        arguments = try HelperArguments.parse(ProcessInfo.processInfo.arguments)
    } catch {
        FileHandle.standardError.write(Data("biscuit-helper: \(error)\n".utf8))
        return 64 // EX_USAGE
    }

    let paths = HelperSessionPaths(root: arguments.sessionDirectory)
    HelperLog.configure(path: paths.helperLog)
    HelperLog.write("biscuit-helper \(HelperVersion.current) starting, euid=\(geteuid())")

    guard geteuid() == 0 else {
        HelperLog.error("not running as root (euid \(geteuid()))")
        FileHandle.standardError.write(Data("biscuit-helper must run as root\n".utf8))
        return 77 // EX_NOPERM
    }

    do {
        try HelperSessionValidator.validateSessionDirectory(
            at: paths.root,
            expectedUID: arguments.clientUID
        )
        let token = try HelperSessionValidator.readToken(
            at: paths.token,
            expectedUID: arguments.clientUID
        )
        guard paths.socketPathFitsInSunPath else {
            throw StartupError("socket path exceeds the AF_UNIX limit of 104 bytes")
        }

        let server = HelperServer(
            configuration: HelperServer.Configuration(
                paths: paths,
                expectedToken: token,
                expectedClientUID: arguments.clientUID,
                expectedClientPrefix: arguments.clientPrefix,
                helperVersion: HelperVersion.current
            ),
            executor: JobExecutor(),
            diagnostics: FileDiagnostics()
        )

        let outcome = try server.run()
        HelperLog.write("session ended: \(outcome)")

        switch outcome {
        case .clientDisconnected, .shutdownRequested:
            return 0
        case .noClientConnected:
            return 3
        case .idleTimeout:
            return 4
        case .authenticationFailed:
            return 77 // EX_NOPERM
        }
    } catch {
        HelperLog.error("startup failed: \(error)")
        FileHandle.standardError.write(Data("biscuit-helper: \(error)\n".utf8))
        return 70 // EX_SOFTWARE
    }
}

// Ignore SIGPIPE globally; the socket layer reports EPIPE instead.
signal(SIGPIPE, SIG_IGN)
exit(bootstrap())
