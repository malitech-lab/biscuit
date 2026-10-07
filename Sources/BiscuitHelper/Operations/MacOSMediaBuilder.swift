import BiscuitKit
import Foundation

/// Wraps Apple's `createinstallmedia`.
///
/// This is deliberately a thin wrapper rather than a reimplementation: the
/// layout of a macOS install volume is undocumented, version-specific, and
/// signed. Anything hand-rolled would break with the next release, and on
/// Apple Silicon an incorrectly built installer volume cannot be booted at all.
struct MacOSMediaBuilder: Sendable {
    private let disk = DiskOperations()

    /// `createinstallmedia` requires a journaled HFS+ volume with this exact
    /// name; it renames the volume itself once it is done.
    private static let stagingVolumeName = "Biscuit Installer"
    private static let minimumCapacity: UInt64 = 16 * 1000 * 1000 * 1000

    func build(
        installerAppURL: URL,
        device: StorageDevice,
        request: JobRequest,
        context: JobContext
    ) async throws -> UInt64 {
        let tool = installerAppURL
            .appendingPathComponent("Contents/Resources/createinstallmedia")

        guard FileManager.default.isExecutableFile(atPath: tool.path) else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorCreateInstallMediaMissing),
                remedy: t(.errorCreateInstallMediaMissingRemedy),
                diagnostics: tool.path
            )
        }

        guard device.sizeBytes >= Self.minimumCapacity else {
            throw BiscuitError.deviceTooSmall(
                required: Self.minimumCapacity,
                available: device.sizeBytes
            )
        }

        try await disk.unmountDisk(device.bsdName, context: context)
        try await disk.wipeSignatures(device: device, context: context)
        try await disk.eraseDisk(
            device: device,
            filesystem: .hfsPlus,
            scheme: .gpt,
            label: Self.stagingVolumeName,
            context: context
        )

        let volume = try await disk.waitForMount(
            wholeDisk: device.bsdName,
            partitionIndex: 2,
            context: context
        )

        context.report(
            phase: .copying,
            phaseFraction: 0,
            detail: t(.detailCreateInstallMediaRunning)
        )
        context.log(.info, "running \(tool.path) --volume \(volume.path)")

        let parser = ToolProgressReporter(context: context, phase: .copying, minimumInterval: 0.3)

        // `--nointeraction` suppresses the confirmation prompt; without it the
        // tool blocks forever waiting on a terminal that does not exist here.
        let result = try await ProcessRunner.runStreaming(
            tool.path,
            arguments: [
                "--volume", volume.path,
                "--nointeraction"
            ],
            environment: WIMTool.sanitisedEnvironment()
        ) { line in
            parser.consume(line)
        }

        guard result.succeeded else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorCreateInstallMediaFailed),
                remedy: Self.remedy(for: result.combinedOutput),
                diagnostics: result.combinedOutput
            )
        }

        context.report(phase: .copying, phaseFraction: 1.0)
        try await disk.synchronise(device: device, context: context)

        // The tool renames the volume, so the original mount path is stale.
        let written = (try? Self.volumeUsedBytes(wholeDisk: device.bsdName)) ?? 0
        context.log(.info, "macOS install media created (\(ByteCount.format(written)))")
        _ = request
        return written
    }

    private static func remedy(for output: String) -> String? {
        let lower = output.lowercased()
        if lower.contains("not enough") || lower.contains("too small") {
            return t(.errorInstallerTooSmallRemedy)
        }
        if lower.contains("damaged") || lower.contains("incomplete") {
            return t(.errorInstallerDamagedRemedy)
        }
        if lower.contains("resource busy") {
            return t(.errorInstallerBusyRemedy)
        }
        return nil
    }

    private static func volumeUsedBytes(wholeDisk: String) throws -> UInt64 {
        let slice = "/dev/\(wholeDisk)s2"
        var statBuffer = statfs()
        guard statfs(slice, &statBuffer) == 0 else { return 0 }
        let total = UInt64(statBuffer.f_blocks) * UInt64(statBuffer.f_bsize)
        let free = UInt64(statBuffer.f_bfree) * UInt64(statBuffer.f_bsize)
        return total > free ? total - free : 0
    }
}
