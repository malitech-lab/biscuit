import Foundation
import Testing
@testable import BiscuitKit

@Suite("Shell-Quoting")
struct ShellQuotingTests {
    @Test("Einfache Pfade werden in Anführungszeichen gesetzt")
    func simplePaths() {
        #expect(ShellQuoting.quote("/Applications/Biscuit.app") == "'/Applications/Biscuit.app'")
    }

    @Test("Leerzeichen bleiben geschützt")
    func spaces() {
        #expect(
            ShellQuoting.quote("/Users/mark/Documents/Default Project")
                == "'/Users/mark/Documents/Default Project'"
        )
    }

    @Test("Eingebettete Anführungszeichen werden korrekt ausgebrochen")
    func embeddedQuote() {
        // The POSIX idiom: close, escaped quote, reopen.
        #expect(ShellQuoting.quote("it's") == "'it'\\''s'")
    }

    @Test("Metazeichen bleiben wirkungslos")
    func metacharacters() {
        // Inside single quotes sh performs no expansion at all, so every one of
        // these is literal. This is what makes the elevation command safe.
        let dangerous = [
            "a; rm -rf /",
            "$(whoami)",
            "`id`",
            "a && b",
            "a | b",
            "*",
            "~/secret",
            "\\",
            "\n"
        ]
        for input in dangerous {
            let quoted = ShellQuoting.quote(input)
            #expect(quoted.hasPrefix("'"))
            #expect(quoted.hasSuffix("'"))
            // Nothing but the escape sequence may introduce an unquoted region.
            let interior = quoted.dropFirst().dropLast()
            #expect(!interior.contains("'") || input.contains("'"))
        }
    }

    @Test("Round-trip durch sh ergibt die Eingabe")
    func roundTripThroughShell() throws {
        let inputs = [
            "/Users/mark/Documents/Default Project/x.iso",
            "it's a file",
            "a;b&c|d",
            "$HOME",
            "weird`name"
        ]
        for input in inputs {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf '%s' \(ShellQuoting.quote(input))"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            #expect(String(decoding: data, as: UTF8.self) == input, "Eingabe: \(input)")
        }
    }
}

@Suite("Prozess-Ausführung")
struct ProcessRunnerTests {
    @Test("Ein langlaufender Prozess blockiert nicht", .timeLimit(.minutes(1)))
    func longRunningProcessCompletes() async throws {
        // Regression test for a deadlock that only appeared for commands taking
        // longer than roughly a second. `Process.waitUntilExit()` spins a
        // CFRunLoop on the calling thread, and a Swift concurrency cooperative
        // thread does not service the sources that deliver the child's exit —
        // so a short command returned fine while anything slower hung forever.
        //
        // In production this would have deadlocked the privileged helper on
        // `diskutil eraseDisk`, mid-operation, with the stick already wiped.
        let started = Date()
        let result = try await ProcessRunner.run(
            "/bin/sleep",
            arguments: ["1.5"],
            timeout: 30
        )
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.succeeded)
        #expect(elapsed >= 1.4, "kehrte zu früh zurück: \(elapsed)s")
        #expect(elapsed < 10, "deutlich zu langsam — Hinweis auf eine Blockade: \(elapsed)s")
    }

    @Test("Mehr parallele Prozesse als Cooperative-Threads", .timeLimit(.minutes(1)))
    func moreConcurrentProcessesThanThreads() async throws {
        // The decisive regression test. An implementation that blocks the calling
        // thread (as `Process.waitUntilExit()` does) parks one cooperative thread
        // per call. Beyond `activeProcessorCount` calls the pool is exhausted and
        // nothing can be scheduled any more — measured: zero of 24 timeout
        // watchdogs fired within four times their deadline.
        let count = ProcessInfo.processInfo.activeProcessorCount * 3
        let started = Date()

        try await withThrowingTaskGroup(of: Int32.self) { group in
            for _ in 0..<count {
                group.addTask {
                    try await ProcessRunner.run(
                        "/bin/sleep", arguments: ["1"], timeout: 30
                    ).exitCode
                }
            }
            var codes: [Int32] = []
            for try await code in group { codes.append(code) }
            #expect(codes.count == count)
            #expect(codes.allSatisfy { $0 == 0 })
        }

        // With a non-blocking implementation these overlap, so the whole group
        // finishes in roughly the duration of one child rather than serialising.
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 15, "Prozesse liefen offenbar nicht parallel: \(elapsed)s")
    }

    @Test("Zeitlimit greift auch bei ausgelastetem Pool", .timeLimit(.minutes(2)))
    func timeoutWorksUnderPoolPressure() async throws {
        // Same pressure, but every child outlives its timeout. If the watchdog
        // cannot be scheduled, this never returns.
        let count = ProcessInfo.processInfo.activeProcessorCount * 2
        let started = Date()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    _ = try? await ProcessRunner.run(
                        "/bin/sleep", arguments: ["120"], timeout: 2
                    )
                }
            }
            for await _ in group {}
        }

        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 60, "Zeitlimit griff bei ausgelastetem Pool nicht: \(elapsed)s")
    }

    @Test("Ausgabe größer als der Pipe-Puffer geht nicht verloren")
    func largeOutputIsNotTruncated() async throws {
        // A 64 KiB pipe buffer fills long before a verbose tool finishes; an
        // implementation that waits for exit before draining would deadlock.
        let result = try await ProcessRunner.run(
            "/usr/bin/yes",
            arguments: ["biscuit"],
            timeout: 10
        )
        // `yes` is killed by the timeout, so a non-zero status is expected; what
        // matters is that a large amount of output arrived intact.
        #expect(result.standardOutput.count > 200_000)
    }

    @Test("Zeitlimit beendet einen hängenden Prozess", .timeLimit(.minutes(1)))
    func timeoutTerminatesProcess() async throws {
        let started = Date()
        _ = try await ProcessRunner.run(
            "/bin/sleep",
            arguments: ["120"],
            timeout: 2
        )
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 20, "Zeitlimit hat nicht gegriffen: \(elapsed)s")
    }

    @Test("Beide Ausgabekanäle werden zeilenweise beobachtet")
    func streamingObservesBothChannels() async throws {
        // wimlib writes its progress to stderr and nothing to stdout. Watching
        // only one channel means no progress at all for the WIM split.
        let lines = LineCollector()
        let result = try await ProcessRunner.runStreaming(
            "/bin/sh",
            arguments: ["-c", "echo aus-stdout; echo aus-stderr >&2"]
        ) { line in
            lines.append(line)
        }

        #expect(result.succeeded)
        #expect(lines.all.contains("aus-stdout"))
        #expect(lines.all.contains("aus-stderr"))
    }

    @Test("Nicht-null Exit-Code wird als Fehler gemeldet")
    func checkedRunThrows() async throws {
        await #expect(throws: ProcessRunner.Failure.self) {
            try await ProcessRunner.runChecked("/bin/sh", arguments: ["-c", "exit 3"])
        }
        let result = try await ProcessRunner.run("/bin/sh", arguments: ["-c", "exit 3"])
        #expect(result.exitCode == 3)
        #expect(!result.succeeded)
    }

    @Test("locate findet nur existierende, ausführbare Pfade")
    func locateResolvesExecutables() {
        // PATH is never consulted: the helper runs as root and an
        // attacker-controlled PATH would be a privilege escalation.
        #expect(ProcessRunner.locate(["/nonexistent", "/bin/sh"]) == "/bin/sh")
        #expect(ProcessRunner.locate(["/etc/hosts"]) == nil) // exists, not executable
        #expect(ProcessRunner.locate([]) == nil)
    }
}

/// Thread-safe line sink for the streaming test.
private final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    var all: [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }
}

@Suite("Prüfsummen")
struct ChecksumTests {
    @Test("SHA-256 stimmt mit bekannten Werten überein")
    func knownVectors() {
        #expect(
            Checksum.hash(Data(), algorithm: .sha256)
                == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        #expect(
            Checksum.hash(Data("abc".utf8), algorithm: .sha256)
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    @Test("Algorithmus wird aus der Hex-Länge erkannt")
    func detection() {
        #expect(Checksum.Algorithm.detect(fromHex: String(repeating: "a", count: 64)) == .sha256)
        #expect(Checksum.Algorithm.detect(fromHex: String(repeating: "a", count: 128)) == .sha512)
        #expect(Checksum.Algorithm.detect(fromHex: String(repeating: "a", count: 40)) == .sha1)
        #expect(Checksum.Algorithm.detect(fromHex: String(repeating: "a", count: 32)) == .md5)
        #expect(Checksum.Algorithm.detect(fromHex: "zu kurz") == nil)
    }

    @Test("Vergleich ignoriert Groß-/Kleinschreibung und Leerraum")
    func comparison() {
        #expect(Checksum.matches("ABCdef", "abcDEF"))
        #expect(Checksum.matches(" abc def ", "abcdef"))
        #expect(!Checksum.matches("abc", "abd"))
        // Different lengths must never compare equal.
        #expect(!Checksum.matches("abc", "abcd"))
        #expect(!Checksum.matches("", ""))
    }

    @Test("Streaming-Hash einer Datei entspricht dem Einmal-Hash")
    func fileHashing() throws {
        let payload = Data((0..<(5 * 1024 * 1024)).map { UInt8($0 % 251) })
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bf-hash-\(UUID().uuidString).bin")
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streamed = try Checksum.hashFile(at: url, algorithm: .sha256)
        #expect(streamed == Checksum.hash(payload, algorithm: .sha256))
    }
}

@Suite("Byte-Formatierung")
struct ByteCountTests {
    @Test("Ausrichtung nach unten auf Blockgrenzen")
    func alignment() {
        #expect(ByteCount.alignDown(1000, to: 512) == 512)
        #expect(ByteCount.alignDown(1024, to: 512) == 1024)
        #expect(ByteCount.alignDown(511, to: 512) == 0)
        #expect(ByteCount.alignDown(4097, to: 4096) == 4096)
        // Guard against a division by zero in the caller.
        #expect(ByteCount.alignDown(1000, to: 0) == 1000)
    }

    @Test("Dauer wird als h:mm:ss bzw. m:ss formatiert")
    func durations() {
        #expect(ByteCount.formatDuration(0) == "0:00")
        #expect(ByteCount.formatDuration(59) == "0:59")
        #expect(ByteCount.formatDuration(61) == "1:01")
        #expect(ByteCount.formatDuration(3661) == "1:01:01")
        #expect(ByteCount.formatDuration(.infinity) == "–")
        #expect(ByteCount.formatDuration(-1) == "–")
    }

    @Test("Datenrate bleibt bei unsinnigen Werten lesbar")
    func rates() {
        #expect(ByteCount.formatRate(bytesPerSecond: 0) == "–")
        #expect(ByteCount.formatRate(bytesPerSecond: .nan) == "–")
        #expect(ByteCount.formatRate(bytesPerSecond: 1_000_000).hasSuffix("/s"))
    }

    @Test("Binäre Hilfsfunktionen")
    func binaryHelpers() {
        #expect(UInt64.mebibytes(1) == 1_048_576)
        #expect(UInt64.gibibytes(1) == 1_073_741_824)
    }
}

@Suite("Phasenplanung")
struct JobPhaseTests {
    @Test("Jede Strategie beginnt mit Vorbereiten und endet mit Fertig")
    func planShape() {
        for strategy in WriteStrategy.allCases {
            for verify in [true, false] {
                let plan = JobPhase.plan(for: strategy, verify: verify)
                #expect(plan.first == .preparing)
                #expect(plan.last == .done)
                #expect(Set(plan).count == plan.count, "Phasen dürfen sich nicht wiederholen")
            }
        }
    }

    @Test("Verifikation erscheint nur, wenn angefordert")
    func verifyPhase() {
        #expect(JobPhase.plan(for: .rawImage, verify: true).contains(.verifying))
        #expect(!JobPhase.plan(for: .rawImage, verify: false).contains(.verifying))
    }

    @Test("Nur Windows-Medien zerlegen ein WIM")
    func wimPhase() {
        #expect(JobPhase.plan(for: .windowsFAT32, verify: false).contains(.splittingWIM))
        #expect(!JobPhase.plan(for: .rawImage, verify: false).contains(.splittingWIM))
        #expect(!JobPhase.plan(for: .eraseOnly, verify: false).contains(.splittingWIM))
    }

    @Test("Rohschreiben partitioniert nicht")
    func rawSkipsPartitioning() {
        // A raw image brings its own partition table; creating one first would
        // simply be overwritten.
        #expect(!JobPhase.plan(for: .rawImage, verify: false).contains(.partitioning))
    }
}

@Suite("Fehler-Normalisierung")
struct BiscuitErrorTests {
    @Test("Bereits typisierte Fehler bleiben unverändert")
    func passThrough() {
        let original = BiscuitError(kind: .writeFailed, message: "x")
        #expect(BiscuitError.wrap(original) == original)
    }

    @Test("Abbruch wird als Abbruch erkannt")
    func cancellation() {
        #expect(BiscuitError.wrap(CancellationError()).isCancellation)
        #expect(BiscuitError.cancelled.isCancellation)
        #expect(!BiscuitError.writeFailed("x").isCancellation)
    }

    @Test("Fehler überleben die JSON-Codierung")
    func codableRoundTrip() throws {
        let original = BiscuitError(
            kind: .verificationFailed,
            message: "Nachricht",
            remedy: "Abhilfe",
            diagnostics: "Diagnose"
        )
        let data = try IPCProtocol.makeEncoder().encode(original)
        let decoded = try IPCProtocol.makeDecoder().decode(BiscuitError.self, from: data)
        #expect(decoded == original)
    }

    @Test("POSIX-Fehler tragen errno in der Diagnose")
    func posixErrors() {
        let error = BiscuitError.posix(EACCES, operation: "open")
        #expect(error.diagnostics?.contains("\(EACCES)") == true)
        #expect(error.message.contains("open"))
    }
}
