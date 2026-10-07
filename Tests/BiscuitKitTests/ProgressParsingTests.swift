import Foundation
import Testing
@testable import BiscuitKit

/// Parsing human-readable tool output is brittle by nature, so it is pinned down
/// against lines recorded from the real tools. If `wimlib` or
/// `createinstallmedia` change their wording, these fail loudly instead of the
/// progress bar silently freezing for ten minutes.
@Suite("Fortschritts-Parsing")
struct ProgressTextParserTests {
    @Test("Echte wimlib-Ausgabe wird erkannt")
    func wimlibLines() {
        // Recorded verbatim from wimlib-imagex 1.14.5.
        #expect(
            ProgressTextParser.percentage(
                in: "Splitting WIM: 6 MiB of 18 MiB (33%) written, part 1 of 3"
            ) == 33
        )
        #expect(
            ProgressTextParser.percentage(
                in: "Splitting WIM: 18 MiB of 18 MiB (100%) written, part 3 of 3"
            ) == 100
        )
        #expect(
            ProgressTextParser.percentage(
                in: "Archiving file data: 0 MiB of 18 MiB (0%) done"
            ) == 0
        )
        #expect(
            ProgressTextParser.percentage(
                in: "Writing LZX-compressed data using 10 threads: 42% done"
            ) == 42
        )
    }

    @Test("Echte createinstallmedia-Ausgabe wird erkannt")
    func createInstallMediaLines() {
        #expect(ProgressTextParser.percentage(in: "Copying to disk: 34% complete") == 34)
        #expect(ProgressTextParser.percentage(in: "Making disk bootable...") == nil)
        #expect(ProgressTextParser.percentage(in: "Install media now available at …") == nil)
    }

    @Test("Zeilen ohne Prozentangabe liefern nil")
    func noPercentage() {
        #expect(ProgressTextParser.percentage(in: "") == nil)
        #expect(ProgressTextParser.percentage(in: "Finished splitting \"test.wim\"") == nil)
        #expect(ProgressTextParser.percentage(in: "%") == nil)
        #expect(ProgressTextParser.percentage(in: "abc%") == nil)
    }

    @Test("Unplausible Werte werden verworfen")
    func implausibleValues() {
        // A misparse that yields 4096 would drive the bar far past the end.
        #expect(ProgressTextParser.percentage(in: "transferred 4096% of nothing") == nil)
        #expect(ProgressTextParser.percentage(in: "0%") == 0)
        #expect(ProgressTextParser.percentage(in: "100%") == 100)
        #expect(ProgressTextParser.percentage(in: "99.5% done") == 99.5)
    }

    @Test("Die letzte Prozentangabe in der Zeile gewinnt")
    func lastOccurrenceWins() {
        #expect(ProgressTextParser.percentage(in: "retry 3%: now at 77% done") == 77)
    }

    @Test("Komma als Dezimaltrenner wird akzeptiert")
    func commaDecimal() {
        // German locales appear in some tool output; treating "," as a thousands
        // separator would yield a wildly wrong figure.
        #expect(ProgressTextParser.percentage(in: "fertig: 42,5%") == 42.5)
    }
}

@Suite("Fortschritts-Meldung aus Tool-Ausgabe")
struct ToolProgressReporterTests {
    private func makeReporter(
        recorder: JobRecorder,
        range: ClosedRange<Double> = 0...1,
        interval: TimeInterval = 0
    ) -> ToolProgressReporter {
        let device = StorageDevice(
            bsdName: "disk99", model: "T", vendor: nil,
            sizeBytes: .gibibytes(8), blockSize: 512, bus: .usb,
            isRemovableMedia: true, isEjectable: true, isWritable: true,
            isSystemDisk: false, volumes: []
        )
        let request = JobRequest.test(strategy: .windowsFAT32, target: device)
        return ToolProgressReporter(
            context: recorder.makeContext(request: request),
            phase: .splittingWIM,
            fractionRange: range,
            minimumInterval: interval
        )
    }

    @Test("Aufsteigende Prozentwerte werden gemeldet")
    func reportsAscendingValues() {
        let recorder = JobRecorder()
        let reporter = makeReporter(recorder: recorder)

        for percent in [0, 10, 25, 50, 75, 100] {
            reporter.consume("Splitting WIM: (\(percent)%) written, part 1 of 2")
        }

        let fractions = recorder.progress
            .filter { $0.phase == .splittingWIM }
            .compactMap(\.phaseFraction)
        #expect(fractions == [0, 0.1, 0.25, 0.5, 0.75, 1.0])
    }

    @Test("Wiederholte Werte verbrauchen das Throttle-Budget nicht")
    func duplicatesAreIgnored() {
        // wimlib emits the same percentage dozens of times. If a repeat reset the
        // throttle, a short operation would report nothing at all — which is the
        // bug this behaviour exists to prevent.
        let recorder = JobRecorder()
        let reporter = makeReporter(recorder: recorder, interval: 0.05)

        reporter.consume("(0%) done")
        for _ in 0..<200 {
            reporter.consume("(0%) done")
        }
        reporter.consume("(50%) done")
        reporter.consume("(100%) done")

        let fractions = recorder.progress.compactMap(\.phaseFraction)
        // 0 and 100 are forced; 50 may be throttled away, but never all three.
        #expect(fractions.contains(0))
        #expect(fractions.contains(1.0))
        #expect(fractions.count <= 3)
    }

    @Test("Rückläufige Werte werden verworfen")
    func nonMonotonicValuesDropped() {
        let recorder = JobRecorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.consume("(50%) done")
        reporter.consume("(20%) done")
        reporter.consume("(60%) done")

        let fractions = recorder.progress.compactMap(\.phaseFraction)
        #expect(fractions == [0.5, 0.6])
    }

    @Test("Werte werden in das Teilintervall skaliert")
    func scalesIntoRange() {
        let recorder = JobRecorder()
        let reporter = makeReporter(recorder: recorder, range: 0.65...1.0)

        reporter.consume("(0%) done")
        reporter.consume("(100%) done")

        let fractions = recorder.progress.compactMap(\.phaseFraction)
        #expect(fractions.first == 0.65)
        #expect(fractions.last == 1.0)
    }

    @Test("Zeilen ohne Prozentwert landen im Protokoll")
    func plainLinesAreLogged() {
        let recorder = JobRecorder()
        let reporter = makeReporter(recorder: recorder)

        reporter.consume("Making disk bootable...")
        reporter.consume("Finished splitting \"install.wim\"")

        #expect(recorder.progress.isEmpty)
        #expect(recorder.logs.count == 2)
        #expect(recorder.logs.allSatisfy { $0.level == .debug })
    }
}
