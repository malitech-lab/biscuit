import BiscuitKit
import Foundation
import Observation

/// Drives one media-creation job from selection to completion and owns every
/// piece of state the UI renders.
///
/// Invariants worth stating, because the UI depends on them:
/// - `phase` only ever moves forward through the plan for the active strategy.
/// - exactly one of `result` / `failure` is set once `state` leaves `.running`.
/// - `logs` is append-only within a run and cleared only when a new run starts.
@MainActor
@Observable
final class JobCoordinator {
    enum State: Equatable {
        case idle
        case inspectingSource
        case ready
        case awaitingAuthorisation
        case running
        case succeeded
        case failed
    }

    // MARK: - Selection

    private(set) var state: State = .idle
    var source: MediaSource?
    var selectedDeviceBSDName: String?
    var strategy: WriteStrategy = .rawImage
    var volumeLabel: String = ""
    var eraseFilesystem: TargetFilesystem = .exfat
    var erasePartitionScheme: PartitionScheme = .gpt
    var verifyAfterWrite = true
    var ejectWhenDone = true

    /// Optional Windows Setup answer file. Only meaningful for `.windowsFAT32`.
    private(set) var answerFile: AnswerFile?
    /// Set when the answer file came from the template rather than a dropped file.
    private(set) var answerTemplate: AnswerFileTemplate?

    /// Catalogue entry the current source came from, if any. Carries the
    /// expanded checksum that the writer verifies as it goes.
    private(set) var catalogueOrigin: CatalogueImage?

    // MARK: - Progress

    private(set) var progress: JobProgress?
    private(set) var phasePlan: [JobPhase] = []
    private(set) var completedPhases: Set<JobPhase> = []
    private(set) var result: JobResult?
    private(set) var failure: BiscuitError?
    private(set) var logs: [LogEntry] = []
    private(set) var activeJobID: UUID?
    private(set) var isCancelling = false

    private let broker: PrivilegeBroker
    private let monitor: DeviceMonitor
    private let inspector = ISOInspector()
    private let preparer = SourcePreparer()
    private let answerFileInspector = AnswerFileInspector()
    private var runTask: Task<Void, Never>?

    /// Caps memory for a long-running job that logs every copied file.
    private static let maximumLogEntries = 2000

    init(broker: PrivilegeBroker, monitor: DeviceMonitor) {
        self.broker = broker
        self.monitor = monitor
    }

    // MARK: - Derived UI state

    var selectedDevice: StorageDevice? {
        guard let selectedDeviceBSDName else { return nil }
        return monitor.device(withBSDName: selectedDeviceBSDName)
    }

    var isRunning: Bool {
        state == .running || state == .awaitingAuthorisation
    }

    var availableStrategies: [WriteStrategy] {
        guard let source else { return [.eraseOnly] }
        return source.supportedStrategies + [.eraseOnly]
    }

    /// Everything blocking the start button, in the order the user should fix it.
    var blockers: [String] {
        var reasons: [String] = []

        guard let device = selectedDevice else {
            reasons.append(t(.blockerSelectTarget))
            return reasons
        }
        if device.isSystemDisk {
            reasons.append(t(.blockerSystemDisk))
        }
        if !device.isWritable {
            reasons.append(t(.blockerReadOnly))
        }

        if strategy == .eraseOnly {
            return reasons
        }

        guard let source else {
            reasons.append(t(.blockerSelectSource))
            return reasons
        }
        if source.supportedStrategies.isEmpty {
            reasons.append(t(.blockerNoBootableMethod))
        }
        if acceptsAnswerFile, let answerFile, !answerFile.isUsable {
            reasons.append(t(.blockerAnswerFileInvalid))
        }
        if !source.supportedStrategies.contains(strategy) {
            reasons.append(t(.blockerMethodMismatch))
        }
        if source.requiredCapacityBytes > device.sizeBytes {
            reasons.append(t(
                .blockerTooSmall,
                ByteCount.format(source.requiredCapacityBytes),
                ByteCount.format(device.sizeBytes)
            ))
        }
        return reasons
    }

    var canStart: Bool {
        !isRunning && blockers.isEmpty && (state == .ready || state == .idle || state == .succeeded || state == .failed)
    }

    /// True when an answer file would actually be honoured.
    ///
    /// Shown only for a detected Windows installer: on a raw write the file
    /// could not be added at all, and offering the option there would promise
    /// something the medium cannot deliver.
    var acceptsAnswerFile: Bool {
        source?.payload == .windowsInstaller && strategy == .windowsFAT32
    }

    var overallFraction: Double? { progress?.overallFraction }

    var currentPhase: JobPhase? { progress?.phase }

    // MARK: - Source selection

    func selectSource(_ url: URL) async {
        state = .inspectingSource
        source = nil
        failure = nil
        result = nil

        do {
            let inspected = try await inspector.inspect(url)
            source = inspected
            // Eine neue Quelle ist ein neuer Auftrag. Die Antwortdatei blieb
            // bisher hängen, und eine einmal zum Ausprobieren erzeugte Vorlage
            // ritt danach auf jedem weiteren Lauf mit — sie landete auf einem
            // Medium, für das der Nutzer sie nie angefordert hatte, und die
            // Installation brach daran ab.
            if answerFile != nil {
                append(.init(
                    level: .warning,
                    source: "app",
                    message: "answer file discarded: a new source starts a new job"
                ))
            }
            answerFile = nil
            answerTemplate = nil
            if let recommended = inspected.recommendedStrategy {
                strategy = recommended
            } else {
                // No bootable path; the user can still erase, but not write this.
                strategy = .eraseOnly
            }
            volumeLabel = Self.defaultLabel(for: inspected)
            state = .ready
            append(.init(
                level: inspected.supportedStrategies.isEmpty ? .warning : .info,
                source: "app",
                message: "\(url.lastPathComponent): \(inspected.payload.displayName)"
            ))
            for note in inspected.detectionNotes {
                append(.init(level: .debug, source: "app", message: note))
            }
        } catch {
            failure = BiscuitError.wrap(error, kind: .sourceUnsupported)
            state = .failed
        }
    }

    // MARK: - Answer file

    /// Reads and validates a dropped answer file.
    ///
    /// Read here rather than in the helper for the same reason as the source
    /// image: the file is almost always in a TCC-protected folder, and the
    /// unprivileged app is the process that holds the user's consent.
    func selectAnswerFile(_ url: URL) {
        do {
            let contents = try Data(contentsOf: url)
            let inspected = answerFileInspector.inspect(
                fileName: url.lastPathComponent,
                contents: contents
            )
            answerFile = inspected

            // Size and findings only — never the contents.
            append(.init(
                level: inspected.isUsable ? .info : .error,
                source: "app",
                message: "answer file \(url.lastPathComponent): \(contents.count) bytes, "
                    + "findings: \(inspected.findings.map(\.kind.rawValue).joined(separator: ",") )"
            ))
        } catch {
            answerFile = nil
            failure = BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorAnswerFileUnreadable),
                remedy: t(.errorSourceUnreadableRemedy),
                diagnostics: String(describing: error)
            )
        }
    }

    /// Generates an answer file from the template and adopts it.
    ///
    /// The architecture is taken from the inspected ISO rather than asked for:
    /// Windows Setup matches `processorArchitecture` strictly and silently
    /// ignores a file that does not match, which is a failure nobody would be
    /// able to diagnose from the finished medium.
    func applyAnswerTemplate(_ template: AnswerFileTemplate) {
        var template = template
        if let detected = source?.windowsMetadata?.commonArchitecture {
            template.architecture = detected
        }
        do {
            answerFile = try template.build(fileName: AnswerFile.standardFileName)
            answerTemplate = template
            failure = nil
        } catch {
            failure = BiscuitError.wrap(error, kind: .internalInconsistency)
        }
    }

    func clearAnswerFile() {
        answerTemplate = nil
        answerFile = nil
    }

    func clearSource() {
        source = nil
        strategy = .eraseOnly
        answerFile = nil
        catalogueOrigin = nil
        state = .idle
    }

    /// Downloads a macOS installer and adopts it as the source.
    ///
    /// Lands in `/Applications`, which is where the privileged helper is
    /// allowed to read from — unlike `~/Downloads`, which macOS privacy
    /// protection guards even against root.
    func useMacOSInstaller(_ installer: MacOSInstaller, service: CatalogueService) {
        state = .inspectingSource
        source = nil
        failure = nil
        result = nil
        catalogueOrigin = nil

        service.fetchMacOSInstaller(installer) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .success(let url):
                Task { await self.selectSource(url) }
            case .failure(let error):
                self.failure = error
                self.state = .failed
            }
        }
    }

    // MARK: - Catalogue

    /// Downloads a catalogue entry and adopts it as the source once verified.
    ///
    /// The download is driven by `CatalogueService`; this only waits for it and
    /// then runs the file through the normal inspection path, so a catalogue
    /// image and a dropped file are treated identically from here on. The one
    /// difference is `catalogueOrigin`, which carries the publisher's checksum
    /// of the decompressed image into the write job.
    func useCatalogueImage(_ image: CatalogueImage, service: CatalogueService) {
        catalogueOrigin = image
        state = .inspectingSource
        source = nil
        failure = nil
        result = nil

        service.download(image)

        Task { [weak self] in
            guard let self else { return }
            // Poll rather than subscribe: the service already publishes its
            // state for the progress UI, and a second notification path would
            // be one more thing to keep consistent.
            while service.downloadState.isBusy {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if Task.isCancelled { return }
            }
            switch service.downloadState {
            case .finished(let finished, let url) where finished.id == image.id:
                await self.selectSource(url)
                // selectSource clears nothing, but a failed inspection must not
                // leave a stale origin attached to a different file.
                if self.source == nil { self.catalogueOrigin = nil }
            case .failed(_, let error):
                self.catalogueOrigin = nil
                self.failure = error
                self.state = .failed
            default:
                self.catalogueOrigin = nil
                self.state = self.source == nil ? .idle : .ready
            }
        }
    }

    private static func defaultLabel(for source: MediaSource) -> String {
        if let label = source.volumeLabel, !label.isEmpty {
            return label
        }
        return source.url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Running

    func start() {
        guard canStart else { return }
        guard let device = selectedDevice else { return }

        let jobID = UUID()
        phasePlan = JobPhase.plan(for: strategy, verify: verifyAfterWrite)
        completedPhases = []
        progress = nil
        result = nil
        failure = nil
        isCancelling = false
        activeJobID = jobID
        logs = []
        state = .awaitingAuthorisation

        append(.init(
            level: .info,
            source: "app",
            message: "starting \(strategy.rawValue) on \(device.bsdName) (\(device.displayName))"
        ))

        runTask = Task { [weak self] in
            await self?.run(jobID: jobID, device: device)
        }
    }

    func cancel() {
        guard isRunning, let activeJobID else { return }
        isCancelling = true
        append(.init(level: .warning, source: "app", message: t(.statusCancelling)))
        Task {
            guard let client = try? await broker.client() else { return }
            try? client.send(.cancelJob(id: activeJobID))
        }
    }

    private func run(jobID: UUID, device: StorageDevice) async {
        // Prepared before elevation so that a problem with the source — a file
        // that vanished, an installer outside /Applications — surfaces without
        // having bothered the user for a password first.
        let prepared: SourcePreparer.Prepared
        do {
            prepared = try await preparer.prepare(source: source, strategy: strategy)
            append(.init(
                level: .debug,
                source: "app",
                message: "source prepared: \(prepared.handle.displayName)"
            ))
        } catch {
            failure = BiscuitError.wrap(error, kind: .sourceUnreadable)
            state = .failed
            append(.init(level: .error, source: "app", message: failure?.message ?? ""))
            return
        }
        defer { Task { await prepared.release() } }

        let request = JobRequest(
            id: jobID,
            strategy: strategy,
            targetBSDName: device.bsdName,
            expectedTargetSizeBytes: device.sizeBytes,
            source: prepared.handle,
            volumeLabel: volumeLabel,
            partitionScheme: strategy == .eraseOnly ? erasePartitionScheme : .gpt,
            filesystem: strategy == .eraseOnly ? eraseFilesystem : .fat32,
            verifyAfterWrite: verifyAfterWrite,
            wimToolPath: BundledTools.wimlibPath,
            // Only for raw writes: a file-copy job assembles the medium rather
            // than reproducing the image byte for byte, so an image-wide digest
            // would never match.
            expectedImageDigest: strategy == .rawImage ? catalogueOrigin?.expandedSHA256 : nil,
            // Only attached where it applies; the helper rejects it otherwise
            // rather than ignoring it.
            answerFile: acceptsAnswerFile ? answerFile : nil
        )

        let client: HelperClient
        do {
            client = try await broker.client()
        } catch {
            failure = BiscuitError.wrap(error, kind: .privilegeDenied)
            state = .failed
            append(.init(level: .error, source: "app", message: failure?.message ?? "unknown error"))
            return
        }

        append(.init(level: .debug, source: "app", message: "helper connected, version \(client.helperVersion)"))
        state = .running

        do {
            // The descriptor must land immediately before the job request; the
            // channel holds its write lock across both so nothing interleaves.
            if let descriptor = prepared.descriptor {
                try client.sendSourceDescriptor(jobID: jobID, descriptor: descriptor)
            }
            try client.send(.runJob(request))
        } catch {
            failure = BiscuitError.wrap(error)
            state = .failed
            return
        }

        // Consume frames until this job reaches a terminal state. Frames for
        // other job IDs are impossible today (the helper serves one job at a
        // time) but are filtered defensively.
        for await response in client.responses {
            switch response {
            case .progress(let update):
                guard update.jobID == request.id else { continue }
                apply(update)

            case .log(let entry):
                append(entry)

            case .jobFinished(let finished):
                guard finished.jobID == request.id else { continue }
                await complete(with: finished, device: device)
                return

            case .jobFailed(let jobID, let error):
                guard jobID == request.id else { continue }
                failure = error
                state = .failed
                append(.init(
                    level: error.isCancellation ? .warning : .error,
                    source: "app",
                    message: error.message
                ))
                return

            case .failure(let error):
                failure = error
                state = .failed
                return

            case .goodbye:
                break

            case .handshakeAccepted, .handshakeRejected, .pong,
                 .deviceInfo, .deviceMissing:
                continue
            }
        }

        // The stream ended without a terminal frame: the helper died.
        if state == .running || state == .awaitingAuthorisation {
            failure = BiscuitError(
                kind: .helperUnavailable,
                message: t(.errorHelperConnectionLost),
                remedy: t(.errorHelperConnectionLostRemedy)
            )
            state = .failed
        }
    }

    private func apply(_ update: JobProgress) {
        // Mark every phase before the current one complete, so a phase that
        // finishes faster than one progress tick still shows as done.
        if let index = phasePlan.firstIndex(of: update.phase) {
            completedPhases.formUnion(phasePlan[..<index])
        }
        progress = update
    }

    private func complete(with finished: JobResult, device: StorageDevice) async {
        completedPhases = Set(phasePlan)
        result = finished
        state = .succeeded

        for warning in finished.warnings {
            append(.init(level: .warning, source: "app", message: warning))
        }
        append(.init(
            level: .info,
            source: "app",
            message: "finished in \(ByteCount.formatDuration(finished.duration))"
                + (finished.bytesWritten > 0 ? ", \(ByteCount.format(finished.bytesWritten)) written" : "")
                + (finished.verified ? ", verification passed" : "")
        ))

        if ejectWhenDone {
            // Ejecting needs no privileges for a device the user owns, so this
            // runs in-process rather than round-tripping through the helper.
            let ejected = try? await ProcessRunner.run(
                DeviceInspector.diskutil,
                arguments: ["eject", "/dev/\(device.bsdName)"],
                timeout: 60
            )
            append(.init(
                level: ejected?.succeeded == true ? .info : .warning,
                source: "app",
                message: ejected?.succeeded == true
                    ? t(.noticeEjected)
                    : t(.warningEjectFailed)
            ))
        }

        await monitor.refresh()
    }

    // MARK: - Logs

    private func append(_ entry: LogEntry) {
        logs.append(entry)
        if logs.count > Self.maximumLogEntries {
            logs.removeFirst(logs.count - Self.maximumLogEntries)
        }
    }

    func exportableLog() -> String {
        DiagnosticsReport.render(
            context: .init(
                appVersion: AppInfo.version,
                appBuild: AppInfo.build,
                osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                target: selectedDevice.map {
                    "\($0.displayName) \($0.bsdName) "
                    + "\(ByteCount.format($0.sizeBytes)) \($0.bus.displayName)"
                },
                source: source.map {
                    "\($0.url.lastPathComponent) \($0.payload.rawValue) "
                    + "\(ByteCount.format($0.sizeBytes))"
                },
                strategy: strategy,
                answerFile: acceptsAnswerFile
                    ? answerFile.map {
                        "\($0.displaySummary)"
                        + (answerTemplate != nil ? " (generated by Biscuit)" : "")
                    }
                    : nil
            ),
            entries: logs.map {
                .init(
                    timestamp: $0.timestamp,
                    level: $0.level.rawValue,
                    source: $0.source,
                    message: $0.message
                )
            },
            failure: failure
        )
    }

    func reset() {
        guard !isRunning else { return }
        state = source == nil ? .idle : .ready
        progress = nil
        result = nil
        failure = nil
        completedPhases = []
        activeJobID = nil
        isCancelling = false
    }
}
