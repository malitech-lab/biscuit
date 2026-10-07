import BiscuitKit
import Foundation

/// Dispatches a validated `JobRequest` to the right strategy and guarantees the
/// invariants that make the operation safe:
///
/// - the target is re-validated against the request immediately before any
///   destructive step, closing the TOCTOU window on recycled BSD names;
/// - the source handle is validated against an allow-list of path prefixes, so
///   holding the session token does not let the app point root at any file;
/// - every exit path reports exactly one terminal frame, so the app can never be
///   left with a spinner that runs forever;
/// - the device is synchronised before success is reported, so pulling the stick
///   as soon as the UI says "done" cannot corrupt it.
struct JobExecutor: JobRunning {
    private let disk = DiskOperations()
    private let rawWriter = RawImageWriter()
    private let windows = WindowsMediaBuilder()
    private let macOS = MacOSMediaBuilder()

    /// - Parameter sourceDescriptor: descriptor received over `SCM_RIGHTS`, if
    ///   the request declared one. Ownership transfers to this call, which closes
    ///   it on every exit path.
    func execute(
        request: JobRequest,
        sourceDescriptor: Int32?,
        emit: @escaping @Sendable (HelperResponse) -> Void,
        cancellation: CancellationFlag
    ) async {
        defer {
            if let sourceDescriptor, sourceDescriptor >= 0 { close(sourceDescriptor) }
        }

        let phases = JobPhase.plan(for: request.strategy, verify: request.verifyAfterWrite)
        let context = JobContext(
            request: request,
            phases: phases,
            cancellation: cancellation,
            emit: emit
        )
        let started = Date()

        do {
            context.report(phase: .preparing, phaseFraction: 0, detail: t(.detailValidatingTarget))

            try request.source.validatePath()
            // Both live on JobRequest in BiscuitKit so they can be tested;
            // this target is an executable the test target cannot import.
            try request.assertSourceMatchesStrategy(descriptor: sourceDescriptor)
            try request.assertAnswerFileApplies()

            let device = try await disk.validateTarget(
                bsdName: request.targetBSDName,
                expectedSizeBytes: request.expectedTargetSizeBytes,
                context: context
            )
            // Vor dem ersten zerstörenden Schritt und vor dem Aushängen: ein
            // `open` auf den Geräteknoten. Der erste echte Lauf scheiterte erst
            // in `wipeSignatures` — da waren alle Volumes schon ausgehängt, und
            // der Nutzer stand mit einem unmontierten Stick und einem errno da.
            // Die Probe kostet einen Systemaufruf und hält den Fehlschlag
            // vollständig harmlos.
            try disk.assertDeviceWritable(device: device, context: context)
            context.report(phase: .preparing, phaseFraction: 1)

            var bytesWritten: UInt64 = 0
            var verified = false
            var warnings: [String] = []

            switch request.strategy {
            case .rawImage:
                guard let descriptor = sourceDescriptor,
                      case .transferredDescriptor = request.source
                else {
                    throw BiscuitError.internalInconsistency(
                        "rawImage requires a transferred descriptor"
                    )
                }
                // Compression is detected from the magic bytes here, not from
                // the file name the app saw: a .img.xz renamed to .img is still
                // xz, and writing it raw yields a disk that silently fails to
                // boot.
                let imageSource = try ImageSourceFactory.make(fileDescriptor: descriptor)
                if imageSource.formatDescription != CompressionFormat.none.displayName {
                    context.log(.info, "source is \(imageSource.formatDescription) compressed")
                }

                try await disk.unmountDisk(device.bsdName, context: context)
                bytesWritten = try await rawWriter.write(
                    source: imageSource,
                    to: device,
                    context: context,
                    expectedDigest: request.expectedImageDigest
                )
                try await disk.synchronise(device: device, context: context)
                if request.verifyAfterWrite {
                    try await rawWriter.verify(
                        source: imageSource,
                        against: device,
                        bytesWritten: bytesWritten,
                        context: context
                    )
                    verified = true
                }

            case .windowsFAT32:
                guard case .mountedDirectory(let path, _) = request.source else {
                    throw BiscuitError.internalInconsistency(
                        "windowsFAT32 requires a mounted directory"
                    )
                }
                bytesWritten = try await windows.build(
                    isoRoot: URL(fileURLWithPath: path, isDirectory: true),
                    device: device,
                    request: request,
                    context: context
                )
                if request.verifyAfterWrite {
                    warnings.append(
                        t(.warningNoByteVerificationFileCopy)
                    )
                }

            case .macOSInstaller:
                guard case .applicationBundle(let path) = request.source else {
                    throw BiscuitError.internalInconsistency(
                        "macOSInstaller requires an application bundle"
                    )
                }
                bytesWritten = try await macOS.build(
                    installerAppURL: URL(fileURLWithPath: path, isDirectory: true),
                    device: device,
                    request: request,
                    context: context
                )
                if request.verifyAfterWrite {
                    warnings.append(
                        t(.warningNoByteVerificationInstaller)
                    )
                }

            case .eraseOnly:
                try await disk.unmountDisk(device.bsdName, context: context)
                try await disk.wipeSignatures(device: device, context: context)
                try await disk.eraseDisk(
                    device: device,
                    filesystem: request.filesystem,
                    scheme: request.partitionScheme,
                    label: request.volumeLabel,
                    context: context
                )
                _ = try? await disk.waitForMount(
                    wholeDisk: device.bsdName,
                    partitionIndex: 2,
                    timeout: 30,
                    context: context
                )
                try await disk.synchronise(device: device, context: context)
                context.report(phase: .finalising, phaseFraction: 1)
            }

            context.report(phase: .done, phaseFraction: 1, detail: t(.detailFinished))
            emit(.jobFinished(JobResult(
                jobID: request.id,
                bytesWritten: bytesWritten,
                duration: Date().timeIntervalSince(started),
                verified: verified,
                warnings: warnings
            )))

        } catch {
            let typed = BiscuitError.wrap(error)
            if typed.isCancellation {
                context.log(
                    .warning,
                    t(.warningCancelledMediaIncomplete)
                )
            } else {
                context.log(
                    .error,
                    typed.message + (typed.diagnostics.map { " — \($0)" } ?? "")
                )
            }
            emit(.jobFailed(jobID: request.id, error: typed))
        }
    }

    /// An answer file only has an effect when the media is assembled file by
    /// file. Accepting it for a raw write would produce a stick that boots but
    /// ignores the file, which is harder to diagnose than a refusal.
}
