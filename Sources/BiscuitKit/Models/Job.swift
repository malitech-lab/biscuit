import Foundation

/// A fully specified, validated unit of work handed to the privileged helper.
public struct JobRequest: Codable, Sendable, Hashable {
    public let id: UUID
    public let strategy: WriteStrategy
    /// Whole-disk BSD name, e.g. `disk4`. Never a partition.
    public let targetBSDName: String
    /// Expected size of the target, re-checked by the helper to catch races
    /// where the user swapped devices between selection and confirmation.
    public let expectedTargetSizeBytes: UInt64
    /// How the helper reaches the input data. Never a raw user-space path.
    public let source: SourceHandle
    public let volumeLabel: String
    public let partitionScheme: PartitionScheme
    public let filesystem: TargetFilesystem
    public let verifyAfterWrite: Bool
    /// Path to a `wimlib-imagex` compatible binary, resolved by the app.
    public let wimToolPath: String?

    /// SHA-256 of the *decompressed* image, when the catalogue knows it.
    ///
    /// Verified while writing. A mismatch leaves the disk without its first
    /// megabyte, and therefore without a partition table — obviously unusable
    /// rather than plausibly complete.
    public let expectedImageDigest: String?

    /// Windows Setup answer file to place in the root of the media.
    ///
    /// Carried as contents rather than a path so the privileged helper never
    /// opens a file in a TCC-protected folder, and so the file cannot be
    /// swapped between validation and writing. Only meaningful for
    /// `.windowsFAT32`; the executor rejects it for any other strategy rather
    /// than silently ignoring it.
    ///
    /// Never logged: answer files routinely contain credentials in plain text.
    public let answerFile: AnswerFile?

    public init(
        id: UUID = UUID(),
        strategy: WriteStrategy,
        targetBSDName: String,
        expectedTargetSizeBytes: UInt64,
        source: SourceHandle,
        volumeLabel: String,
        partitionScheme: PartitionScheme,
        filesystem: TargetFilesystem,
        verifyAfterWrite: Bool,
        wimToolPath: String? = nil,
        expectedImageDigest: String? = nil,
        answerFile: AnswerFile? = nil
    ) {
        self.id = id
        self.strategy = strategy
        self.targetBSDName = targetBSDName
        self.expectedTargetSizeBytes = expectedTargetSizeBytes
        self.source = source
        self.volumeLabel = volumeLabel
        self.partitionScheme = partitionScheme
        self.filesystem = filesystem
        self.verifyAfterWrite = verifyAfterWrite
        self.wimToolPath = wimToolPath
        self.expectedImageDigest = expectedImageDigest
        self.answerFile = answerFile
    }
}

/// Coarse phases, so the UI can show a stable step list regardless of strategy.
public enum JobPhase: String, Codable, Sendable, CaseIterable {
    case preparing
    case unmounting
    case partitioning
    case mounting
    case writing
    case copying
    case splittingWIM = "splitting_wim"
    case flushing
    case verifying
    case finalising
    case done

    public var displayName: String {
        switch self {
        case .preparing: return t(.phasePreparing)
        case .unmounting: return t(.phaseUnmounting)
        case .partitioning: return t(.phasePartitioning)
        case .mounting: return t(.phaseMounting)
        case .writing: return t(.phaseWriting)
        case .copying: return t(.phaseCopying)
        case .splittingWIM: return t(.phaseSplittingWIM)
        case .flushing: return t(.phaseFlushing)
        case .verifying: return t(.phaseVerifying)
        case .finalising: return t(.phaseFinalising)
        case .done: return t(.phaseDone)
        }
    }

    /// Phases shown in the UI step indicator for a given strategy.
    public static func plan(for strategy: WriteStrategy, verify: Bool) -> [JobPhase] {
        var phases: [JobPhase]
        switch strategy {
        case .rawImage:
            phases = [.preparing, .unmounting, .writing, .flushing]
        case .windowsFAT32:
            phases = [.preparing, .unmounting, .partitioning, .mounting, .copying, .splittingWIM, .flushing]
        case .macOSInstaller:
            phases = [.preparing, .unmounting, .partitioning, .copying, .flushing]
        case .eraseOnly:
            phases = [.preparing, .unmounting, .partitioning, .finalising]
        }
        if verify { phases.append(.verifying) }
        phases.append(.done)
        return phases
    }
}

/// Incremental progress pushed from the helper to the app.
public struct JobProgress: Codable, Sendable, Hashable {
    public let jobID: UUID
    public let phase: JobPhase
    /// 0…1 within the current phase, or nil when indeterminate.
    public let phaseFraction: Double?
    /// 0…1 across the whole job, or nil when indeterminate.
    public let overallFraction: Double?
    public let bytesProcessed: UInt64
    public let bytesTotal: UInt64?
    public let bytesPerSecond: Double?
    public let secondsRemaining: Double?
    public let detail: String?

    public init(
        jobID: UUID,
        phase: JobPhase,
        phaseFraction: Double?,
        overallFraction: Double?,
        bytesProcessed: UInt64,
        bytesTotal: UInt64?,
        bytesPerSecond: Double?,
        secondsRemaining: Double?,
        detail: String?
    ) {
        self.jobID = jobID
        self.phase = phase
        self.phaseFraction = phaseFraction
        self.overallFraction = overallFraction
        self.bytesProcessed = bytesProcessed
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.secondsRemaining = secondsRemaining
        self.detail = detail
    }
}

/// Terminal result of a job.
public struct JobResult: Codable, Sendable, Hashable {
    public let jobID: UUID
    public let bytesWritten: UInt64
    public let duration: Double
    public let verified: Bool
    public let warnings: [String]

    public init(jobID: UUID, bytesWritten: UInt64, duration: Double, verified: Bool, warnings: [String]) {
        self.jobID = jobID
        self.bytesWritten = bytesWritten
        self.duration = duration
        self.verified = verified
        self.warnings = warnings
    }
}

/// Severity for log lines surfaced in the UI log pane.
public enum LogLevel: String, Codable, Sendable, Comparable {
    case debug
    case info
    case warning
    case error

    private var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rank < rhs.rank }
}

public struct LogEntry: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let source: String
    public let message: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: LogLevel,
        source: String,
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.source = source
        self.message = message
    }
}

// MARK: - Preconditions checked by the privileged side

public extension JobRequest {
    /// Rejects an answer file that the chosen strategy cannot honour.
    ///
    /// Only a FAT32 Windows medium has a filesystem to put the file on. A raw
    /// image write is a byte-for-byte copy with nowhere to add anything, and
    /// `createinstallmedia` builds a volume Biscuit does not lay out itself.
    ///
    /// Rejected rather than silently dropped, deliberately: a user who supplied
    /// an answer file and received a medium that ignores it has no way to tell
    /// that happened, and would discover it only when Setup asks questions the
    /// file was meant to answer.
    func assertAnswerFileApplies() throws {
        guard answerFile != nil else { return }
        guard strategy == .windowsFAT32 else {
            throw BiscuitError(
                kind: .internalInconsistency,
                message: t(.errorAnswerFileWrongStrategy),
                diagnostics: "answer file supplied for strategy \(strategy.rawValue)"
            )
        }
    }

    /// Rejects a request whose source handle cannot serve its strategy.
    ///
    /// Checked before anything destructive happens, because the mismatch would
    /// otherwise surface after the target had already been erased — the user
    /// loses the stick's contents and gains nothing.
    ///
    /// - Parameter descriptor: the file descriptor the helper actually received
    ///   over the socket, or `nil`. Passed in rather than read from the request
    ///   because a descriptor cannot travel inside JSON: the request can *claim*
    ///   `.transferredDescriptor` while no descriptor arrived.
    func assertSourceMatchesStrategy(descriptor: Int32?) throws {
        switch (strategy, source) {
        case (.rawImage, .transferredDescriptor):
            guard let descriptor, descriptor >= 0 else {
                throw BiscuitError.internalInconsistency("descriptor missing")
            }
        case (.windowsFAT32, .mountedDirectory):
            break
        case (.macOSInstaller, .applicationBundle):
            break
        case (.eraseOnly, .none):
            break
        default:
            throw BiscuitError.internalInconsistency(
                "strategy \(strategy.rawValue) does not match source \(source)"
            )
        }
    }
}
