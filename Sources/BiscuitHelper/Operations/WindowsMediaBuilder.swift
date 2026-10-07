import BiscuitKit
import Foundation

/// Builds a UEFI-bootable Windows installation stick on a single FAT32 partition.
///
/// Why not a raw copy: Microsoft's ISOs contain no hybrid MBR and no isolinux
/// boot sector. Written byte-for-byte, the firmware finds no FAT filesystem in
/// the first partition and skips the device. The supported layout is a real
/// FAT32 volume with the ISO's contents copied onto it, which UEFI firmware
/// boots directly via `EFI\BOOT\BOOTX64.EFI`.
///
/// Why FAT32 and not exFAT or NTFS: UEFI firmware is only required to implement
/// FAT. exFAT is not readable by firmware, and macOS has no NTFS write support.
/// The resulting 4 GiB per-file ceiling is worked around by splitting
/// `install.wim` into `install.swm` parts, which Windows Setup reads natively.
struct WindowsMediaBuilder: Sendable {
    /// This process's own executable, used to find the vendored `wimlib-imagex`
    /// sibling without consulting the request.
    static var ownExecutable: URL? {
        if let url = Bundle.main.executableURL { return url }
        guard let first = ProcessInfo.processInfo.arguments.first else { return nil }
        return URL(fileURLWithPath: first)
    }

    private let disk = DiskOperations()
    private let copier = FileTreeCopier()

    private static let fat32FileLimit: UInt64 = 4 * 1024 * 1024 * 1024 - 1
    private static let installImageDirectory = "sources"

    /// `isoRoot` is a read-only mount the *app* attached. The helper does not
    /// mount the image itself: `hdiutil attach -readonly` needs no privileges,
    /// and doing it unprivileged keeps the ISO's own path — which is usually in
    /// a TCC-protected folder — out of the root process entirely.
    func build(
        isoRoot: URL,
        device: StorageDevice,
        request: JobRequest,
        context: JobContext
    ) async throws -> UInt64 {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: isoRoot.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw BiscuitError(
                kind: .mountFailed,
                message: t(.errorImageDetached),
                remedy: t(.errorSourceGoneRemedy),
                diagnostics: isoRoot.path
            )
        }

        try await disk.unmountDisk(device.bsdName, context: context)
        try await disk.wipeSignatures(device: device, context: context)
        try await disk.eraseDisk(
            device: device,
            filesystem: .fat32,
            scheme: .gpt,
            label: request.volumeLabel,
            context: context
        )

        let destination = try await disk.waitForMount(
            wholeDisk: device.bsdName,
            partitionIndex: 2,
            context: context
        )

        return try await copyContents(
            from: isoRoot,
            to: destination,
            device: device,
            request: request,
            context: context
        )
    }

    // MARK: - Copy + split

    private func copyContents(
        from isoRoot: URL,
        to destination: URL,
        device: StorageDevice,
        request: JobRequest,
        context: JobContext
    ) async throws -> UInt64 {
        // Any file above the FAT32 ceiling is held back from the plain copy and
        // handled by the split step instead.
        let plan = try copier.plan(source: isoRoot) { _, size in
            size > Self.fat32FileLimit
        }

        let oversized = plan.skipped
        for file in oversized {
            context.log(
                .info,
                "\(file.relativePath) is \(ByteCount.format(file.sizeBytes)), will be split"
            )
        }

        // Validate capacity before destroying anything further. The split output
        // is slightly larger than the input because each part repeats the WIM
        // header and the XML metadata.
        let splitOverhead = oversized.reduce(UInt64(0)) { $0 + $1.sizeBytes / 50 }
        let required = plan.totalBytes
            + oversized.reduce(0) { $0 + $1.sizeBytes }
            + splitOverhead
        let free = try Self.availableCapacity(at: destination)
        guard required <= free else {
            throw BiscuitError.deviceTooSmall(required: required, available: free)
        }

        // Reserve the tail of the copy phase for the split, so the bar does not
        // jump from 60 % to 100 % and then sit still for ten minutes.
        let copyShare: Double = oversized.isEmpty ? 1.0 : 0.65

        try copier.execute(
            plan: plan,
            destination: destination,
            context: context,
            phase: .copying,
            fractionRange: 0...copyShare
        )

        var totalBytes = plan.totalBytes

        if !oversized.isEmpty {
            // The path in the request is a *preference*, not an instruction:
            // it names the executable of a child process that runs as root, so
            // it is validated before use and skipped if it fails. The vendored
            // copy is found from the helper's own location, which the client
            // cannot influence.
            let wimTool = WIMTool.locateTrusted(
                preferring: request.wimToolPath,
                helperExecutable: Self.ownExecutable
            ) { rejection in
                context.log(.warning, rejection.diagnostics ?? "tool path rejected")
            }
            guard let wimTool else { throw WIMTool.missingToolError() }
            if let version = await wimTool.version() {
                context.log(.debug, "wimlib: \(version)")
            }

            let shareEach = 1.0 / Double(oversized.count)
            for (index, file) in oversized.enumerated() {
                try context.cancellation.check()
                let lower = Double(index) * shareEach
                let upper = Double(index + 1) * shareEach
                totalBytes += try await splitOversizedImage(
                    file: file,
                    destination: destination,
                    tool: wimTool,
                    context: context,
                    fractionRange: lower...upper
                )
            }
        }

        if let answerFile = request.answerFile {
            totalBytes += try Self.writeAnswerFile(answerFile, to: destination, context: context)
        }

        try await disk.synchronise(device: device, context: context)
        try Self.assertBootable(
            destination: destination,
            expectsAnswerFile: request.answerFile != nil,
            context: context
        )
        return totalBytes
    }

    // MARK: - Answer file

    /// Writes `autounattend.xml` into the root of the media.
    ///
    /// The root of the removable volume is where Windows Setup looks; a copy
    /// anywhere else is simply ignored, which is the failure mode this function
    /// exists to avoid.
    ///
    /// The contents are never logged — answer files routinely carry a local
    /// account password, a product key or domain credentials in plain text.
    private static func writeAnswerFile(
        _ answerFile: AnswerFile,
        to destination: URL,
        context: JobContext
    ) throws -> UInt64 {
        // Re-derived from the bytes, not read off the request. `findings`
        // travels with the file, and `isUsable` is computed from it, so
        // checking `isUsable` here would be asking the client whether its own
        // file is acceptable. That is what this code did before.
        try answerFile.assertWritable()

        // Always written under the name Setup searches for, whatever the user
        // called the file they dropped.
        let target = destination.appendingPathComponent(AnswerFile.standardFileName)

        do {
            try answerFile.contents.write(to: target, options: [.atomic])
        } catch {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorAnswerFileWriteFailed),
                diagnostics: String(describing: error)
            )
        }

        // Size only, never contents.
        context.log(
            .info,
            "wrote \(AnswerFile.standardFileName) (\(answerFile.contents.count) bytes)"
                + (answerFile.containsSecrets ? " — contains credentials in plain text" : "")
        )
        return UInt64(answerFile.contents.count)
    }

    /// Splits one oversized image into the destination, converting ESD to WIM first
    /// when necessary.
    private func splitOversizedImage(
        file: FileTreeCopier.PlannedFile,
        destination: URL,
        tool: WIMTool,
        context: JobContext,
        fractionRange: ClosedRange<Double>
    ) async throws -> UInt64 {
        let relativeDirectory = (file.relativePath as NSString).deletingLastPathComponent
        let targetDirectory = relativeDirectory.isEmpty
            ? destination
            : destination.appendingPathComponent(relativeDirectory)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )

        let baseName = (file.source.lastPathComponent as NSString).deletingPathExtension
        let extensionName = file.source.pathExtension.lowercased()
        let swmURL = targetDirectory.appendingPathComponent("\(baseName).swm")

        if extensionName == "wim" {
            try await tool.split(
                source: file.source,
                destination: swmURL,
                context: context,
                fractionRange: fractionRange
            )
        } else {
            // ESD is a solid archive; wimsplit cannot operate on it directly, so
            // it is first exported to a normal WIM in a scratch location.
            let scratch = try Self.makeScratchDirectory()
            defer { try? FileManager.default.removeItem(at: scratch) }
            let intermediate = scratch.appendingPathComponent("\(baseName).wim")

            let midpoint = fractionRange.lowerBound
                + (fractionRange.upperBound - fractionRange.lowerBound) * 0.7
            try await tool.exportToWIM(
                source: file.source,
                destination: intermediate,
                context: context,
                fractionRange: fractionRange.lowerBound...midpoint
            )
            try await tool.split(
                source: intermediate,
                destination: swmURL,
                context: context,
                fractionRange: midpoint...fractionRange.upperBound
            )
        }

        let parts = try Self.splitParts(matching: baseName, in: targetDirectory)
        guard !parts.isEmpty else {
            throw BiscuitError(
                kind: .wimSplitFailed,
                message: t(.errorWimNoPartsProduced),
                diagnostics: targetDirectory.path
            )
        }
        let written = parts.reduce(UInt64(0)) { $0 + $1.sizeBytes }
        context.log(
            .info,
            "produced \(parts.count) parts (\(ByteCount.format(written))): \(parts.map(\.name).joined(separator: ", "))"
        )
        return written
    }

    // MARK: - Post-conditions

    /// Fails loudly if the stick lacks the files UEFI firmware needs. Catching
    /// this here is far better than the user discovering it at a black screen.
    private static func assertBootable(
        destination: URL,
        expectsAnswerFile: Bool,
        context: JobContext
    ) throws {
        let fm = FileManager.default
        let required = [
            "EFI/BOOT/BOOTX64.EFI",
            "sources/boot.wim"
        ]

        var missing: [String] = []
        for relative in required {
            // FAT32 is case-insensitive, but the mount may not be, so probe both.
            let variants = [relative, relative.lowercased(), relative.uppercased()]
            let found = variants.contains {
                fm.fileExists(atPath: destination.appendingPathComponent($0).path)
            }
            if !found { missing.append(relative) }
        }

        guard missing.isEmpty else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorMediaIncomplete),
                remedy: t(.errorMediaIncompleteRemedy, missing.joined(separator: ", ")),
                diagnostics: missing.joined(separator: ", ")
            )
        }

        let installImages = (try? fm.contentsOfDirectory(
            atPath: destination.appendingPathComponent(installImageDirectory).path
        )) ?? []
        let hasInstallPayload = installImages.contains {
            let lower = $0.lowercased()
            return lower.hasPrefix("install.") &&
                (lower.hasSuffix(".wim") || lower.hasSuffix(".swm") || lower.hasSuffix(".esd"))
        }
        guard hasInstallPayload else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorInstallImageMissing),
                remedy: t(.errorInstallImageMissingRemedy)
            )
        }

        // An answer file that silently failed to land looks exactly like a
        // successful run until Setup asks for input on the target machine.
        if expectsAnswerFile {
            let answerPath = destination.appendingPathComponent(AnswerFile.standardFileName)
            let written = fm.fileExists(atPath: answerPath.path)
                || fm.fileExists(atPath: destination
                    .appendingPathComponent(AnswerFile.standardFileName.uppercased()).path)
            guard written else {
                throw BiscuitError(
                    kind: .copyFailed,
                    message: t(.errorAnswerFileMissingAfterWrite),
                    remedy: t(.errorAnswerFileMissingAfterWriteRemedy),
                    diagnostics: answerPath.path
                )
            }
        }

        context.log(.info, "boot files verified: EFI/BOOT/BOOTX64.EFI, sources/boot.wim, sources/install.*")
    }

    // MARK: - Helpers

    private struct SplitPart: Sendable {
        let name: String
        let sizeBytes: UInt64
    }

    private static func splitParts(
        matching baseName: String,
        in directory: URL
    ) throws -> [SplitPart] {
        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(atPath: directory.path)
        let prefix = baseName.lowercased()
        return entries
            .filter { $0.lowercased().hasSuffix(".swm") && $0.lowercased().hasPrefix(prefix) }
            .sorted()
            .map { name in
                let path = directory.appendingPathComponent(name).path
                let attributes = try? fm.attributesOfItem(atPath: path)
                let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
                return SplitPart(name: name, sizeBytes: size)
            }
    }

    private static func availableCapacity(at url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity else {
            throw BiscuitError.internalInconsistency(
                "free space unavailable for \(url.path)"
            )
        }
        return UInt64(max(available, 0))
    }

    /// Scratch space for ESD→WIM conversion. Placed on the boot volume because
    /// the USB stick itself cannot hold the intermediate file.
    private static func makeScratchDirectory() throws -> URL {
        let base = URL(fileURLWithPath: "/private/var/tmp", isDirectory: true)
            .appendingPathComponent("biscuit-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return base
    }
}
