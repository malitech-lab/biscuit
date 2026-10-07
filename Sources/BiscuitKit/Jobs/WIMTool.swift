import Foundation

/// Frontend for `wimlib-imagex`, used to split `install.wim` into `install.swm`
/// parts that fit FAT32's 4 GiB per-file limit.
///
/// Windows Setup reads split WIM sets natively — it looks for `install.swm`,
/// `install2.swm`, … alongside `install.wim`'s original location. This is the
/// same mechanism Microsoft's own `dism /split-image` produces, so the resulting
/// stick is indistinguishable from an officially supported one.
public struct WIMTool: Sendable {
    /// Part size in mebibytes. 3800 leaves comfortable headroom under 4096 MiB
    /// for the FAT32 limit, which applies to the on-disk allocation rather than
    /// the logical size `wimsplit` targets.
    public static let partSizeMegabytes = 3800

    public let executablePath: String

    public init(executablePath: String) {
        self.executablePath = executablePath
    }

    // Deliberately no `locate(preferring:)` any more. It accepted a
    // client-supplied path, placed it at the head of the candidate list and
    // checked nothing but `isExecutableFile` — in a process running as root.
    // Removed rather than left deprecated, so it cannot be reached by accident.
    // Use `locateTrusted(preferring:helperExecutable:onRejection:)`.

    public static func missingToolError() -> BiscuitError {
        BiscuitError(
            kind: .wimToolMissing,
            message: t(.errorWimToolMissing),
            remedy: t(.errorWimToolMissingRemedy),
            diagnostics: "wimlib-imagex not found in the app bundle, /opt/homebrew/bin or /usr/local/bin"
        )
    }

    public func version() async -> String? {
        let result = try? await ProcessRunner.run(
            executablePath,
            arguments: ["--version"],
            timeout: 20
        )
        return result?.succeeded == true
            ? result?.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
    }

    /// Splits `source` into `destination` (`…/install.swm`) plus siblings.
    ///
    /// - Parameter partSizeMegabytes: overridable so tests can split a small
    ///   fixture into several parts without producing a multi-gigabyte file.
    ///   Production always uses the default.
    public func split(
        source: URL,
        destination: URL,
        context: JobContext,
        fractionRange: ClosedRange<Double> = 0...1,
        partSizeMegabytes: Int = WIMTool.partSizeMegabytes
    ) async throws {
        context.log(.info, "splitting \(source.lastPathComponent) into \(partSizeMegabytes) MiB parts")
        context.report(
            phase: .splittingWIM,
            phaseFraction: fractionRange.lowerBound,
            detail: t(.detailSplittingWIM)
        )

        let progress = ToolProgressReporter(
            context: context,
            phase: .splittingWIM,
            fractionRange: fractionRange
        )

        let result = try await ProcessRunner.runStreaming(
            executablePath,
            arguments: [
                "split",
                source.path,
                destination.path,
                String(partSizeMegabytes)
            ],
            environment: Self.sanitisedEnvironment()
        ) { line in
            progress.consume(line)
        }

        guard result.succeeded else {
            throw BiscuitError(
                kind: .wimSplitFailed,
                message: t(.errorWimSplitFailed),
                remedy: t(.errorWimSplitFailedRemedy),
                diagnostics: result.combinedOutput
            )
        }

        context.report(
            phase: .splittingWIM,
            phaseFraction: fractionRange.upperBound,
            detail: nil
        )
    }

    /// Converts a solid archive (`install.esd`) into a standard WIM so that it
    /// can be split. Significantly slower than a plain split because every
    /// resource is recompressed.
    public func exportToWIM(
        source: URL,
        destination: URL,
        context: JobContext,
        fractionRange: ClosedRange<Double> = 0...1
    ) async throws {
        context.log(.warning, "\(source.lastPathComponent) is a solid archive; converting to WIM first")
        context.report(
            phase: .splittingWIM,
            phaseFraction: fractionRange.lowerBound,
            detail: t(.detailConvertingESD)
        )

        let progress = ToolProgressReporter(
            context: context,
            phase: .splittingWIM,
            fractionRange: fractionRange
        )

        let result = try await ProcessRunner.runStreaming(
            executablePath,
            arguments: [
                "export",
                source.path,
                "all",
                destination.path,
                "--compress=LZX"
            ],
            environment: Self.sanitisedEnvironment()
        ) { line in
            progress.consume(line)
        }

        guard result.succeeded else {
            throw BiscuitError(
                kind: .wimSplitFailed,
                message: t(.errorWimConvertFailed, source.lastPathComponent),
                diagnostics: result.combinedOutput
            )
        }
    }

    /// Running as root means an inherited `PATH`, `DYLD_*` or `LD_*` variable
    /// would be a privilege-escalation vector. The child gets a fixed, minimal
    /// environment instead.
    public static func sanitisedEnvironment() -> [String: String] {
        [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "HOME": "/var/root"
        ]
    }
}

// MARK: - Trusting the tool path

public extension WIMTool {
    /// The only basename accepted. No arbitrary executable names.
    static let expectedToolName = "wimlib-imagex"

    /// Directories a root process may execute the tool from.
    ///
    /// The first entry is derived from the helper's *own* location rather than
    /// taken from the request, which is what makes the vendored copy usable
    /// without trusting anything the client said: `Scripts/bundle.sh` places
    /// `wimlib-imagex` next to `biscuit-helper` in `Contents/MacOS`.
    static func allowedToolDirectories(helperExecutable: URL?) -> [String] {
        var directories: [String] = []
        if let helperExecutable {
            directories.append(
                helperExecutable.deletingLastPathComponent().path
                    .appending("/")
            )
        }
        directories.append(contentsOf: [
            "/opt/homebrew/bin/",
            "/usr/local/bin/",
            "/opt/local/bin/"
        ])
        return directories
    }

    /// Rejects a tool path the privileged side must not execute.
    ///
    /// ## Why this exists
    ///
    /// `JobRequest.wimToolPath` is a path chosen by the unprivileged app and
    /// used as the executable of a child process that runs as **root**. It was
    /// passed straight into the old `locate(preferring:)`, which put it at the head of
    /// the candidate list, and from there into `Process.executableURL`. The only
    /// check it ever faced was `isExecutableFile`.
    ///
    /// That contradicted what `SECURITY.md` claims the helper refuses to
    /// believe — source paths are checked against an allow-list for exactly
    /// this reason — and it is not covered by the documented limitation about
    /// an attacker who can read the session token. That limitation argues such
    /// an attacker could raise their own admin prompt instead; this gap needed
    /// no prompt at all, because the user had already approved *Biscuit*, not
    /// whatever binary the request happened to name.
    ///
    /// ## What is checked
    ///
    /// - the basename, so only `wimlib-imagex` can be launched;
    /// - the directory, against the allow-list above;
    /// - traversal surviving standardisation;
    /// - group- and world-writability of both the file **and** its directory,
    ///   because a writable directory lets anyone swap the file afterwards.
    ///
    /// ## What remains true and is not fixed here
    ///
    /// On Apple Silicon, Homebrew owns `/opt/homebrew` as the installing
    /// *user*. A user who has already replaced their own
    /// `/opt/homebrew/bin/wimlib-imagex` therefore still influences what runs
    /// as root. That is weaker than executing an arbitrary path — it needs
    /// prior modification of a known location, and it is the same binary the
    /// user chose to install — but it is a real residual limit and is written
    /// down in `SECURITY.md` rather than implied away.
    static func validateToolPath(_ path: String, helperExecutable: URL?) throws {
        let standardised = (path as NSString).standardizingPath

        guard !standardised.contains("/../") else {
            throw toolPathRejected(standardised, reason: "path traversal")
        }
        guard (standardised as NSString).lastPathComponent == expectedToolName else {
            throw toolPathRejected(
                standardised,
                reason: "unexpected basename, requires \(expectedToolName)"
            )
        }

        let allowed = allowedToolDirectories(helperExecutable: helperExecutable)
        guard allowed.contains(where: { standardised.hasPrefix($0) }) else {
            throw toolPathRejected(
                standardised,
                reason: "outside allowed directories: \(allowed.joined(separator: ", "))"
            )
        }

        // World-writable is always fatal: anyone at all could swap the file.
        //
        // Group-writable is judged by *which* group. The first version rejected
        // it outright and was both wrong and useless: Homebrew on Apple Silicon
        // installs `/opt/homebrew/bin` as `admin`, mode 775, so every real
        // machine tripped it — and the hardcoded fallback list then ran the
        // very same path without any check at all. The warning was noise and
        // the rule bought nothing.
        //
        // Members of `admin` and `wheel` can already become root with `sudo`.
        // Write access to a directory they could escalate through anyway is not
        // an additional step up, and SECURITY.md records it as an accepted
        // limit. Any other group is a genuine widening and stays fatal.
        for candidate in [standardised, (standardised as NSString).deletingLastPathComponent] {
            guard let attributes = try? FileManager.default
                .attributesOfItem(atPath: candidate),
                let permissions = attributes[.posixPermissions] as? NSNumber
            else {
                throw toolPathRejected(candidate, reason: "cannot stat")
            }
            let mode = permissions.uint16Value
            guard mode & 0o002 == 0 else {
                throw toolPathRejected(
                    candidate,
                    reason: String(format: "world-writable (mode %o)", mode)
                )
            }
            if mode & 0o020 != 0 {
                let gid = (attributes[.groupOwnerAccountID] as? NSNumber)?.uint32Value ?? .max
                guard Self.isPrivilegedGroup(gid) else {
                    let name = Self.groupName(gid) ?? "gid \(gid)"
                    throw toolPathRejected(
                        candidate,
                        reason: String(format: "group-writable by '%@' (mode %o)", name, mode)
                    )
                }
            }
        }
    }

    /// Groups whose members can already reach root through `sudo`.
    static func isPrivilegedGroup(_ gid: UInt32) -> Bool {
        guard let name = groupName(gid) else { return false }
        return name == "admin" || name == "wheel"
    }

    static func groupName(_ gid: UInt32) -> String? {
        guard let entry = getgrgid(gid_t(gid)), let raw = entry.pointee.gr_name else {
            return nil
        }
        return String(cString: raw)
    }

    private static func toolPathRejected(_ path: String, reason: String) -> BiscuitError {
        BiscuitError(
            kind: .wimToolMissing,
            message: t(.errorWimToolRejected),
            remedy: t(.errorWimToolRejectedRemedy),
            diagnostics: "rejected tool path \(path): \(reason)"
        )
    }

    /// Locates the tool, accepting the client's preference only if it validates.
    ///
    /// A rejected preference is *skipped* rather than fatal: the hardcoded
    /// fallbacks may still produce a working tool, and refusing the whole job
    /// because the app offered a bad path would turn a hardening check into a
    /// denial of service.
    static func locateTrusted(
        preferring preferred: String?,
        helperExecutable: URL?,
        onRejection: ((BiscuitError) -> Void)? = nil
    ) -> WIMTool? {
        var candidates: [String] = []

        if let preferred {
            do {
                try validateToolPath(preferred, helperExecutable: helperExecutable)
                candidates.append(preferred)
            } catch let error as BiscuitError {
                onRejection?(error)
            } catch {
                onRejection?(BiscuitError.wrap(error, kind: .wimToolMissing))
            }
        }

        // Derived from the helper's own location, so the vendored copy is
        // reachable without the client naming it.
        if let helperExecutable {
            candidates.append(
                helperExecutable.deletingLastPathComponent()
                    .appendingPathComponent(expectedToolName).path
            )
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/\(expectedToolName)",
            "/usr/local/bin/\(expectedToolName)",
            "/opt/local/bin/\(expectedToolName)"
        ])

        // Die Ersatzkandidaten durchlaufen dieselbe Prüfung. Vorher taten sie
        // es nicht, und der Pfad, den die Prüfung gerade abgelehnt hatte, wurde
        // eine Zeile später aus dieser Liste doch benutzt.
        for candidate in candidates {
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            do {
                try validateToolPath(candidate, helperExecutable: helperExecutable)
                return WIMTool(executablePath: candidate)
            } catch let error as BiscuitError {
                onRejection?(error)
            } catch {
                onRejection?(BiscuitError.wrap(error, kind: .wimToolMissing))
            }
        }
        return nil
    }
}
