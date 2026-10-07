import Foundation
import Testing
@testable import BiscuitKit

/// What the first real USB stick taught.
///
/// A run against real hardware failed with:
///
///     ERROR helper: Der Zugriff auf den Geräteknoten wurde verweigert.
///                   — errno 1: Operation not permitted
///
/// and that was all the user got: no remedy, a bare errno, and a stick whose
/// volumes had already been unmounted. The message was also wrong in substance —
/// it said "denied" as if permissions were missing, when the helper runs as
/// root and file modes cannot stop it.
///
/// `errno 1` is `EPERM`, not `EACCES`. Measured on the same machine: an
/// unprivileged process opening `/dev/rdisk7` gets `EACCES` (13). The helper got
/// `EPERM` (1) — on macOS the signature of a *policy* denial, which for raw disk
/// access means Full Disk Access, a permission that applies to root as well and
/// that cannot be requested programmatically.
@Suite("Diagnose des Gerätezugriffs")
struct DeviceAccessDiagnosisTests {
    @Test("EPERM nennt Festplattenvollzugriff und sagt, was zu tun ist")
    func epermNamesFullDiskAccess() {
        let error = DeviceAccessDiagnosis.error(errno: EPERM, path: "/dev/rdisk7")
        #expect(error.kind == .partitioningFailed)
        #expect(error.message == t(.errorDeviceNeedsFullDiskAccess))
        // The point of the whole change: there is now a way forward, and it
        // says something the message does not.
        let remedy = error.remedy ?? ""
        #expect(!remedy.isEmpty, "ohne Abhilfe steht der Nutzer wieder da wie vorher")
        #expect(remedy != error.message)
        #expect(remedy.count > 40, "Abhilfe zu knapp, um befolgbar zu sein")
    }

    @Test("EACCES wird nicht mit EPERM verwechselt")
    func eaccesIsDistinct() {
        // The two are different situations and must not share a message. EACCES
        // would mean the helper is not root — a bug on our side, not something
        // the user can grant their way out of.
        let eperm = DeviceAccessDiagnosis.error(errno: EPERM, path: "/dev/rdisk7")
        let eacces = DeviceAccessDiagnosis.error(errno: EACCES, path: "/dev/rdisk7")
        #expect(eperm.message != eacces.message)
        #expect(eacces.message == t(.errorDeviceAccessDenied))
    }

    @Test("EBUSY nennt andere Programme als Ursache")
    func ebusyNamesOtherPrograms() {
        let error = DeviceAccessDiagnosis.error(errno: EBUSY, path: "/dev/rdisk7")
        #expect(error.message == t(.errorDeviceBusy))
        #expect(error.remedy == t(.errorDeviceBusyRemedy))
    }

    @Test("Die Diagnose nennt Pfad, errno und Klartext")
    func diagnosticsAreComplete() {
        // A bug report has to be reproducible from this line alone.
        for code in [EPERM, EACCES, EBUSY, EIO] {
            let error = DeviceAccessDiagnosis.error(errno: code, path: "/dev/rdisk9")
            let diagnostics = error.diagnostics ?? ""
            #expect(diagnostics.contains("/dev/rdisk9"))
            #expect(diagnostics.contains("errno \(code)"))
            #expect(diagnostics.contains("O_WRONLY"))
            #expect(
                diagnostics.contains(String(cString: strerror(code))),
                Comment(rawValue: "Klartext fehlt für errno \(code)")
            )
        }
    }

    @Test("Ein unbekanntes errno führt nicht zu einer irreführenden Abhilfe")
    func unknownErrnoHasNoRemedy() {
        // Suggesting Full Disk Access for an I/O error would send the user down
        // a dead end — a failing stick is not a permissions problem.
        let error = DeviceAccessDiagnosis.error(errno: EIO, path: "/dev/rdisk7")
        #expect(error.message == t(.errorDeviceAccessDenied))
        #expect(error.remedy == nil)
    }

    @Test("Die Abhilfe benennt den Ort der Einstellung und das Neustarten")
    func remedyIsSpecific() throws {
        // Specific enough to follow without searching: the pane, the toggle,
        // and the fact that the app has to be restarted afterwards.
        for language in ["en", "de"] {
            guard let url = L10n.resourceBundle.url(
                forResource: "Localizable", withExtension: "strings",
                subdirectory: nil, localization: language
            ),
                let table = try? PropertyListSerialization.propertyList(
                    from: Data(contentsOf: url), options: [], format: nil
                ) as? [String: String],
                let remedy = table["error.device_needs_full_disk_access.remedy"]
            else {
                Issue.record(Comment("Abhilfe fehlt in \(language)"))
                continue
            }
            let lower = remedy.lowercased()
            #expect(lower.contains("full disk access") || lower.contains("festplattenvollzugriff"))
            #expect(lower.contains("biscuit"))
            // And it must say that nothing was damaged — the run stops before
            // anything is written.
            #expect(
                lower.contains("nothing") || lower.contains("nichts"),
                Comment(rawValue: "\(language): sagt nicht, dass nichts verändert wurde")
            )
        }
    }
}

/// The preflight that keeps the failure harmless.
@Suite("Vorabprüfung des Geräteknotens")
struct DevicePreflightCallSiteTests {
    private static func source(_ relative: String) -> String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent(relative)
            if let data = try? Data(contentsOf: candidate) {
                return String(decoding: data, as: UTF8.self)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Die Probe läuft vor dem Aushängen und vor jeder Methode")
    func preflightRunsFirst() throws {
        // The first real run failed only at wipeSignatures, by which time every
        // volume had been unmounted. Nothing was lost, but the user was left
        // with an unmounted stick for no reason.
        let executor = try #require(
            Self.source("Sources/BiscuitHelper/Operations/JobExecutor.swift"),
            "JobExecutor nicht gefunden"
        )
        let probe = try #require(executor.range(of: "assertDeviceWritable"))
        let unmount = try #require(executor.range(of: "disk.unmountDisk("))
        let dispatch = try #require(executor.range(of: "switch request.strategy"))
        #expect(probe.lowerBound < unmount.lowerBound, "Probe läuft nach dem Aushängen")
        #expect(probe.lowerBound < dispatch.lowerBound, "Probe deckt nicht alle Methoden ab")
    }
}
