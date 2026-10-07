import BiscuitKit
import Foundation

/// Privileged disk topology changes. Every destructive call re-validates the
/// target against the request first, so a stale BSD name can never be acted on.
struct DiskOperations: Sendable {
    private let inspector = DeviceInspector()

    /// Re-reads the device and refuses to continue unless it still matches what
    /// the user agreed to destroy.
    ///
    /// This closes a real TOCTOU window: BSD names are recycled, so `disk4` can
    /// be a 32 GB stick at selection time and an external 4 TB archive by the
    /// time the user clicks the confirm button.
    func validateTarget(
        bsdName: String,
        expectedSizeBytes: UInt64,
        context: JobContext
    ) async throws -> StorageDevice {
        let device = try await inspector.inspectDevice(bsdName: bsdName)

        guard !device.isSystemDisk else {
            throw BiscuitError(
                kind: .deviceNotEligible,
                message: t(.errorDeviceIsSystemDisk, bsdName),
                remedy: t(.errorDeviceIsSystemDiskRemedy)
            )
        }
        guard device.isEligibleTarget else {
            throw BiscuitError.deviceNotEligible(bsdName)
        }

        // Tolerate a small reported-size drift between diskutil invocations, but
        // nothing that could plausibly be a different physical device.
        let drift = device.sizeBytes > expectedSizeBytes
            ? device.sizeBytes - expectedSizeBytes
            : expectedSizeBytes - device.sizeBytes
        guard drift <= .mebibytes(1) else {
            throw BiscuitError(
                kind: .deviceNotFound,
                message: t(.errorDeviceChanged),
                remedy: t(.errorDeviceChangedRemedy, bsdName),
                diagnostics: "expected \(expectedSizeBytes) bytes, found \(device.sizeBytes) bytes"
            )
        }

        context.log(.info, "target confirmed: \(device.displayName) \(device.bsdName) \(ByteCount.format(device.sizeBytes))")
        return device
    }

    // MARK: - Unmount

    func unmountDisk(_ bsdName: String, context: JobContext) async throws {
        context.report(phase: .unmounting, detail: t(.detailUnmounting, bsdName))

        // A plain unmountDisk fails when any volume is busy; forcing is correct
        // here because the user has explicitly agreed to erase this device.
        let result = try await ProcessRunner.run(
            DeviceInspector.diskutil,
            arguments: ["unmountDisk", "force", "/dev/\(bsdName)"],
            timeout: 120
        )

        if !result.succeeded {
            // "was already unmounted" is a success for our purposes.
            let output = result.combinedOutput.lowercased()
            let benign = output.contains("unmounted") || output.contains("not mounted")
            guard benign else {
                throw BiscuitError(
                    kind: .deviceBusy,
                    message: t(.errorDeviceBusy),
                    remedy: t(.errorDeviceBusyRemedy),
                    diagnostics: result.combinedOutput
                )
            }
        }
        context.log(.info, "all volumes unmounted")
    }

    // MARK: - Partition table hygiene

    /// Overwrites the first and last megabyte of the device.
    ///
    /// Required before repartitioning: a leftover GPT backup header at the end
    /// of the disk makes macOS, Windows and Linux disagree about the layout, and
    /// stale filesystem superblocks cause probing tools to misidentify the stick.
    func wipeSignatures(device: StorageDevice, context: JobContext) async throws {
        context.report(phase: .partitioning, phaseFraction: 0.1, detail: t(.detailWipingSignatures))

        let fd = open(device.rawDevicePath, O_WRONLY)
        guard fd >= 0 else {
            throw BiscuitError(
                kind: .partitioningFailed,
                message: t(.errorDeviceAccessDenied),
                diagnostics: "errno \(errno): \(String(cString: strerror(errno)))"
            )
        }
        defer { close(fd) }

        let blockSize = UInt64(max(device.blockSize, 512))
        let wipeLength = ByteCount.alignDown(.mebibytes(1), to: blockSize)
        let zeros = [UInt8](repeating: 0, count: Int(wipeLength))

        func write(at offset: UInt64) throws {
            guard lseek(fd, off_t(offset), SEEK_SET) >= 0 else {
                throw BiscuitError.posix(errno, operation: "lseek")
            }
            var written = 0
            try zeros.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                while written < zeros.count {
                    let count = Darwin.write(fd, base.advanced(by: written), zeros.count - written)
                    if count > 0 { written += count; continue }
                    if errno == EINTR { continue }
                    throw BiscuitError.posix(errno, operation: "write")
                }
            }
        }

        try write(at: 0)
        if device.sizeBytes > wipeLength * 2 {
            let tailOffset = ByteCount.alignDown(device.sizeBytes - wipeLength, to: blockSize)
            // A short tail write is not fatal; the primary header is what matters.
            try? write(at: tailOffset)
        }

        _ = fsync(fd)
        context.log(.info, "partition signatures wiped")
    }

    // MARK: - Erase / partition

    /// Single-partition layout. `diskutil eraseDisk` writes a fresh partition
    /// map and a fresh filesystem in one atomic-ish step.
    func eraseDisk(
        device: StorageDevice,
        filesystem: TargetFilesystem,
        scheme: PartitionScheme,
        label: String,
        context: JobContext
    ) async throws {
        let safeLabel = Self.sanitiseVolumeLabel(label, filesystem: filesystem)
        context.report(phase: .partitioning, phaseFraction: 0.3, detail: t(.detailFormatting, filesystem.rawValue))
        context.log(.info, "diskutil eraseDisk \(filesystem.diskutilValue) \(safeLabel) \(scheme.diskutilValue) /dev/\(device.bsdName)")

        let result = try await ProcessRunner.run(
            DeviceInspector.diskutil,
            arguments: [
                "eraseDisk",
                filesystem.diskutilValue,
                safeLabel,
                scheme.diskutilValue,
                "/dev/\(device.bsdName)"
            ],
            timeout: 900
        )

        guard result.succeeded else {
            throw BiscuitError(
                kind: .partitioningFailed,
                message: t(.errorPartitioningFailed),
                remedy: t(.errorPartitioningFailedRemedy),
                diagnostics: result.combinedOutput
            )
        }
        context.report(phase: .partitioning, phaseFraction: 1.0)
    }

    // MARK: - Mount discovery

    /// Waits for the given partition index of a device to appear with a mount
    /// point. `diskutil eraseDisk` mounts asynchronously, so polling is required.
    func waitForMount(
        wholeDisk: String,
        partitionIndex: Int,
        timeout: TimeInterval = 60,
        context: JobContext
    ) async throws -> URL {
        context.report(phase: .mounting, detail: t(.detailWaitingForMount))
        let deadline = Date().addingTimeInterval(timeout)
        var lastDiagnostic = "no reply from diskutil"

        while Date() < deadline {
            try context.cancellation.check()
            let slice = "\(wholeDisk)s\(partitionIndex)"
            let result = try? await ProcessRunner.run(
                DeviceInspector.diskutil,
                arguments: ["info", "-plist", slice],
                timeout: 20
            )

            if let result, result.succeeded,
               let data = result.standardOutput.data(using: .utf8),
               let info = try? PropertyListSerialization.propertyList(
                   from: data, options: [], format: nil
               ) as? [String: Any] {
                if let mountPoint = info["MountPoint"] as? String, !mountPoint.isEmpty {
                    context.log(.info, "\(slice) mounted at \(mountPoint)")
                    return URL(fileURLWithPath: mountPoint)
                }
                // Partition exists but is not mounted; ask for it explicitly.
                _ = try? await ProcessRunner.run(
                    DeviceInspector.diskutil,
                    arguments: ["mount", slice],
                    timeout: 60
                )
                lastDiagnostic = "\(slice) exists but is not mounted"
            } else {
                lastDiagnostic = result?.combinedOutput ?? lastDiagnostic
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        throw BiscuitError(
            kind: .mountFailed,
            message: t(.errorMountNotAppearing),
            remedy: t(.errorMountNotAppearingRemedy),
            diagnostics: lastDiagnostic
        )
    }

    // MARK: - Finalisation

    /// Flushes the device's own write cache. Without this, pulling the stick
    /// immediately after the progress bar completes can corrupt the filesystem.
    func synchronise(device: StorageDevice, context: JobContext) async throws {
        context.report(phase: .flushing, phaseFraction: 0.2, detail: t(.detailFlushing))
        _ = try? await ProcessRunner.run("/bin/sync", arguments: [], timeout: 120)

        // DKIOCSYNCHRONIZECACHE on the buffered node forces the drive to commit.
        let fd = open(device.devicePath, O_RDONLY)
        if fd >= 0 {
            defer { close(fd) }
            let dkiocSynchronizeCache: UInt = 0x20000400 | (UInt(UInt8(ascii: "d")) << 8) | 22
            _ = ioctl(fd, dkiocSynchronizeCache)
        }
        context.report(phase: .flushing, phaseFraction: 1.0)
    }

    func eject(device: StorageDevice, context: JobContext) async {
        let result = try? await ProcessRunner.run(
            DeviceInspector.diskutil,
            arguments: ["eject", "/dev/\(device.bsdName)"],
            timeout: 120
        )
        if result?.succeeded == true {
            context.log(.info, "disk ejected")
        } else {
            context.log(.warning, "eject failed")
        }
    }

    // MARK: - Label hygiene

    /// Volume labels reach `diskutil` as a separate argv entry, so there is no
    /// injection risk — but FAT32 and exFAT have hard character and length
    /// limits, and an invalid label makes the whole erase fail. Enforced here
    /// rather than trusted from the app.
    static func sanitiseVolumeLabel(_ raw: String, filesystem: TargetFilesystem) -> String {
        VolumeLabel.sanitise(raw, filesystem: filesystem)
    }
}
