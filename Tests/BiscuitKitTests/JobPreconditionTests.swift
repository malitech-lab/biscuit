import Foundation
import Testing
@testable import BiscuitKit

/// The two checks the privileged side makes before anything destructive runs.
///
/// Both used to be private statics inside `JobExecutor`, which lives in an
/// executable target the test target cannot import — so neither had a single
/// test, despite both guarding the moment just before a disk gets erased. They
/// now live on `JobRequest` for exactly that reason.
@Suite("Vorbedingungen eines Auftrags")
struct JobPreconditionTests {
    private func request(
        strategy: WriteStrategy,
        source: SourceHandle,
        answerFile: AnswerFile? = nil
    ) -> JobRequest {
        JobRequest(
            strategy: strategy,
            targetBSDName: "disk9",
            expectedTargetSizeBytes: .gibibytes(16),
            source: source,
            volumeLabel: "WIN",
            partitionScheme: .gpt,
            filesystem: .fat32,
            verifyAfterWrite: false,
            answerFile: answerFile
        )
    }

    private var usableAnswerFile: AnswerFile {
        AnswerFileInspector().inspect(
            fileName: "autounattend.xml",
            contents: Data(#"<unattend xmlns="urn:schemas-microsoft-com:unattend"/>"#.utf8)
        )
    }

    // MARK: - Answer file applicability

    @Test("Eine Antwortdatei ist bei Windows-FAT32 zulässig")
    func answerFileAllowedForWindows() throws {
        try request(
            strategy: .windowsFAT32,
            source: .mountedDirectory(path: "/Volumes/X", displayName: "x.iso"),
            answerFile: usableAnswerFile
        ).assertAnswerFileApplies()
    }

    @Test("Eine Antwortdatei wird bei jeder anderen Strategie abgelehnt")
    func answerFileRejectedElsewhere() throws {
        // Rejected rather than silently dropped: a user who supplied a file and
        // got a medium that ignores it has no way to notice, and would find out
        // only when Setup asks what the file was meant to answer.
        let cases: [(WriteStrategy, SourceHandle)] = [
            (.rawImage, .transferredDescriptor(sizeBytes: 100, displayName: "x.img")),
            (.macOSInstaller, .applicationBundle(path: "/Applications/Install macOS.app")),
            (.eraseOnly, .none)
        ]
        for (strategy, source) in cases {
            let error = try #require(throws: BiscuitError.self) {
                try request(
                    strategy: strategy, source: source, answerFile: usableAnswerFile
                ).assertAnswerFileApplies()
            }
            #expect(
                error.diagnostics?.contains(strategy.rawValue) == true,
                Comment(rawValue: "Strategie nicht in der Diagnose: \(strategy.rawValue)")
            )
        }
    }

    @Test("Ohne Antwortdatei ist jede Strategie in Ordnung")
    func noAnswerFileIsAlwaysFine() throws {
        for strategy in WriteStrategy.allCases {
            try request(strategy: strategy, source: .none).assertAnswerFileApplies()
        }
    }

    // MARK: - Source matching strategy

    @Test("Die vier zulässigen Paarungen werden angenommen")
    func validPairingsAccepted() throws {
        try request(
            strategy: .rawImage,
            source: .transferredDescriptor(sizeBytes: 100, displayName: "x.img")
        ).assertSourceMatchesStrategy(descriptor: 7)

        try request(
            strategy: .windowsFAT32,
            source: .mountedDirectory(path: "/Volumes/X", displayName: "x.iso")
        ).assertSourceMatchesStrategy(descriptor: nil)

        try request(
            strategy: .macOSInstaller,
            source: .applicationBundle(path: "/Applications/Install macOS.app")
        ).assertSourceMatchesStrategy(descriptor: nil)

        try request(strategy: .eraseOnly, source: .none)
            .assertSourceMatchesStrategy(descriptor: nil)
    }

    @Test("Ein behaupteter Deskriptor ohne wirklichen wird abgelehnt")
    func claimedDescriptorWithoutOneIsRejected() throws {
        // A descriptor cannot travel inside JSON. The request can claim
        // `.transferredDescriptor` while nothing arrived over the socket, so
        // the real descriptor is passed in separately and checked.
        let error = try #require(throws: BiscuitError.self) {
            try request(
                strategy: .rawImage,
                source: .transferredDescriptor(sizeBytes: 100, displayName: "x.img")
            ).assertSourceMatchesStrategy(descriptor: nil)
        }
        #expect(error.diagnostics?.contains("descriptor missing") == true)
    }

    @Test("Ein negativer Deskriptor gilt als fehlend")
    func negativeDescriptorCountsAsMissing() throws {
        // -1 is what a failed `recvmsg` leaves behind, and using it as a file
        // descriptor would read from whatever fd 0 happens to be.
        #expect(throws: BiscuitError.self) {
            try request(
                strategy: .rawImage,
                source: .transferredDescriptor(sizeBytes: 100, displayName: "x.img")
            ).assertSourceMatchesStrategy(descriptor: -1)
        }
    }

    @Test("Jede falsche Paarung wird abgelehnt")
    func everyMismatchIsRejected() throws {
        // Checked exhaustively rather than by example: the `default` branch is
        // what catches a strategy added later, and an incomplete switch here
        // would let a mismatch through to the erase step.
        let sources: [SourceHandle] = [
            .none,
            .transferredDescriptor(sizeBytes: 100, displayName: "x.img"),
            .mountedDirectory(path: "/Volumes/X", displayName: "x.iso"),
            .applicationBundle(path: "/Applications/Install macOS.app")
        ]
        let validPairs: Set<String> = [
            "raw_image|transferredDescriptor",
            "windows_fat32|mountedDirectory",
            "macos_installer|applicationBundle",
            "erase_only|none"
        ]

        var checked = 0
        for strategy in WriteStrategy.allCases {
            for source in sources {
                let key = "\(strategy.rawValue)|\(Self.label(for: source))"
                let job = request(strategy: strategy, source: source)
                if validPairs.contains(key) {
                    try job.assertSourceMatchesStrategy(descriptor: 7)
                } else {
                    #expect(
                        throws: BiscuitError.self,
                        Comment(rawValue: "Paarung \(key) wurde angenommen")
                    ) {
                        try job.assertSourceMatchesStrategy(descriptor: 7)
                    }
                }
                checked += 1
            }
        }
        #expect(checked == WriteStrategy.allCases.count * sources.count)
        #expect(checked == 16, "unerwartete Zahl an Paarungen: \(checked)")
    }

    private static func label(for source: SourceHandle) -> String {
        switch source {
        case .none: return "none"
        case .transferredDescriptor: return "transferredDescriptor"
        case .mountedDirectory: return "mountedDirectory"
        case .applicationBundle: return "applicationBundle"
        }
    }
}

/// Confirms the helper calls the checks rather than merely owning them.
@Suite("Vorbedingungen: Aufrufstelle im Helfer")
struct JobPreconditionCallSiteTests {
    private static var executorSource: String? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<5 {
            let candidate = directory.appendingPathComponent(
                "Sources/BiscuitHelper/Operations/JobExecutor.swift"
            )
            if let data = try? Data(contentsOf: candidate) {
                return String(decoding: data, as: UTF8.self)
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    @Test("Beide Prüfungen werden vor dem Löschen aufgerufen")
    func bothChecksAreCalledBeforeErasing() throws {
        let source = try #require(Self.executorSource, "JobExecutor nicht gefunden")
        #expect(source.contains("request.assertAnswerFileApplies()"))
        #expect(source.contains("request.assertSourceMatchesStrategy(descriptor:"))

        // Order matters: both must precede the target validation, which is the
        // last step before anything destructive.
        let answerIndex = source.range(of: "assertAnswerFileApplies()")?.lowerBound
        let sourceIndex = source.range(of: "assertSourceMatchesStrategy(descriptor:")?.lowerBound
        let validateIndex = source.range(of: "disk.validateTarget(")?.lowerBound
        let answer = try #require(answerIndex)
        let match = try #require(sourceIndex)
        let validate = try #require(validateIndex)
        #expect(answer < validate, "Antwortdatei-Prüfung läuft zu spät")
        #expect(match < validate, "Quellen-Prüfung läuft zu spät")
    }
}
