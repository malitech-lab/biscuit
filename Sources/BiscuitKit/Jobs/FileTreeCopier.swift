import Foundation

/// Recursive file-tree copy with byte-accurate progress and cooperative
/// cancellation.
///
/// `FileManager.copyItem` is not used because it reports no progress on a
/// multi-gigabyte tree, cannot be interrupted, and aborts the whole operation on
/// the first unreadable entry — all three matter when the destination is a slow
/// USB stick and the source is a 6 GB ISO.
public struct FileTreeCopier: Sendable {
    public static let bufferSize = 4 * 1024 * 1024

    public init() {}

    public struct Plan: Sendable {
        /// Files to copy, as (source, destination-relative-path, size).
        public let files: [PlannedFile]
        public let directories: [String]
        public let totalBytes: UInt64
        /// Files deliberately skipped, e.g. an oversized `install.wim` that will
        /// be split into the destination separately.
        public let skipped: [PlannedFile]
    }

    public struct PlannedFile: Sendable {
        public let source: URL
        public let relativePath: String
        public let sizeBytes: UInt64

        public init(source: URL, relativePath: String, sizeBytes: UInt64) {
            self.source = source
            self.relativePath = relativePath
            self.sizeBytes = sizeBytes
        }

        /// `install.wim` can be split into `install.swm` chunks that Windows
        /// Setup reads natively. `install.esd` cannot be split directly.
        public var isSplittableWIM: Bool {
            source.pathExtension.lowercased() == "wim"
        }
    }

    /// Builds a copy plan, excluding any path for which `shouldSkip` returns true.
    public func plan(
        source: URL,
        shouldSkip: (String, UInt64) -> Bool
    ) throws -> Plan {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]

        // Resolve symlinks in the root before enumerating. Without this the
        // enumerator can hand back `/private/var/...` for a root given as
        // `/var/...`, a prefix comparison then fails, and every file collapses to
        // its own basename — which silently flattens the whole tree. On a Windows
        // stick that puts EFI/BOOT/BOOTX64.EFI in the root and the medium does
        // not boot.
        let root = source.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = root.pathComponents

        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorCopySourceUnlistable),
                diagnostics: source.path
            )
        }

        var files: [PlannedFile] = []
        var skipped: [PlannedFile] = []
        var directories: [String] = []
        var total: UInt64 = 0

        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))

            // A path that cannot be expressed relative to the root is a hard
            // error: guessing would mean writing a file to the wrong place.
            guard let relative = Self.relativePath(
                of: item,
                rootComponents: rootComponents
            ) else {
                throw BiscuitError(
                    kind: .copyFailed,
                    message: t(.errorCopyUnexpectedPath),
                    diagnostics: "\(item.path) is not under \(root.path)"
                )
            }

            if values?.isDirectory == true {
                directories.append(relative)
                continue
            }
            // Symlinks on an ISO have no meaning on FAT32; skip rather than fail.
            if values?.isSymbolicLink == true { continue }
            guard values?.isRegularFile == true else { continue }

            let size = UInt64(values?.fileSize ?? 0)
            let entry = PlannedFile(source: item, relativePath: relative, sizeBytes: size)

            if shouldSkip(relative, size) {
                skipped.append(entry)
            } else {
                files.append(entry)
                total += size
            }
        }

        return Plan(files: files, directories: directories, totalBytes: total, skipped: skipped)
    }

    /// Expresses `item` relative to a root given as path components.
    ///
    /// Component-wise rather than string-prefix comparison, so that a trailing
    /// slash, a `.` segment or a resolved symlink cannot produce a wrong answer.
    /// Returns `nil` when `item` is not inside the root at all.
    static func relativePath(of item: URL, rootComponents: [String]) -> String? {
        let itemComponents = item.standardizedFileURL.pathComponents
        guard itemComponents.count > rootComponents.count else { return nil }
        guard Array(itemComponents.prefix(rootComponents.count)) == rootComponents else {
            return nil
        }
        return itemComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    /// Executes a plan. Progress is reported against `plan.totalBytes` scaled
    /// into `[fractionStart, fractionEnd]` of the copy phase, so a caller that
    /// also splits a WIM afterwards can present one continuous bar.
    public func execute(
        plan: Plan,
        destination: URL,
        context: JobContext,
        phase: JobPhase = .copying,
        fractionRange: ClosedRange<Double> = 0...1
    ) throws {
        let fm = FileManager.default

        // Create the directory skeleton first; sorting by depth guarantees
        // parents exist before children.
        for relative in plan.directories.sorted(by: { $0.components(separatedBy: "/").count < $1.components(separatedBy: "/").count }) {
            try context.cancellation.check()
            let target = destination.appendingPathComponent(relative)
            if !fm.fileExists(atPath: target.path) {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            }
        }

        let buffer = try AlignedBuffer(size: Self.bufferSize, alignment: 4096)
        var copied: UInt64 = 0
        var throughput = ThroughputEstimator()
        var throttle = ProgressThrottle()

        func emit(force: Bool, detail: String?) {
            guard throttle.shouldEmit(force: force) else { return }
            let local = plan.totalBytes > 0 ? Double(copied) / Double(plan.totalBytes) : 1
            let scaled = fractionRange.lowerBound
                + local * (fractionRange.upperBound - fractionRange.lowerBound)
            context.report(
                phase: phase,
                phaseFraction: scaled,
                bytesProcessed: copied,
                bytesTotal: plan.totalBytes,
                bytesPerSecond: throughput.rate,
                secondsRemaining: throughput.secondsRemaining(
                    processed: copied,
                    total: plan.totalBytes
                ),
                detail: detail
            )
        }

        emit(force: true, detail: t(.detailCopyingFiles, plan.files.count))

        for file in plan.files {
            try context.cancellation.check()
            let target = destination.appendingPathComponent(file.relativePath)
            try fm.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.copyFile(
                from: file.source,
                to: target,
                buffer: buffer,
                cancellation: context.cancellation
            ) { chunkBytes in
                copied += chunkBytes
                _ = throughput.update(bytes: copied)
                emit(force: false, detail: file.relativePath)
            }
        }

        copied = plan.totalBytes
        emit(force: true, detail: nil)
        context.log(.info, "copied \(plan.files.count) files (\(ByteCount.format(plan.totalBytes)))")
    }

    // MARK: - Single file

    private static func copyFile(
        from source: URL,
        to destination: URL,
        buffer: AlignedBuffer,
        cancellation: CancellationFlag,
        onChunk: (UInt64) -> Void
    ) throws {
        let sourceFD = open(source.path, O_RDONLY)
        guard sourceFD >= 0 else {
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorCopySourceUnreadable, source.lastPathComponent),
                diagnostics: "open: errno \(errno)"
            )
        }
        defer { close(sourceFD) }
        _ = fcntl(sourceFD, F_NOCACHE, 1)
        _ = fcntl(sourceFD, F_RDAHEAD, 1)

        let destinationFD = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard destinationFD >= 0 else {
            let code = errno
            throw BiscuitError(
                kind: .copyFailed,
                message: t(.errorCopyTargetUnwritable, destination.lastPathComponent),
                remedy: code == ENAMETOOLONG
                    ? t(.errorCopyNameTooLongRemedy)
                    : nil,
                diagnostics: "open: errno \(code): \(String(cString: strerror(code)))"
            )
        }
        defer { close(destinationFD) }

        while true {
            try cancellation.check()
            let readCount = Darwin.read(sourceFD, buffer.pointer, buffer.size)
            if readCount == 0 { break }
            if readCount < 0 {
                if errno == EINTR { continue }
                throw BiscuitError(
                    kind: .copyFailed,
                    message: t(.errorCopyReadFailed, source.lastPathComponent),
                    diagnostics: "read: errno \(errno)"
                )
            }

            var written = 0
            while written < readCount {
                let result = Darwin.write(
                    destinationFD,
                    buffer.pointer.advanced(by: written),
                    readCount - written
                )
                if result > 0 { written += result; continue }
                if errno == EINTR { continue }
                let code = errno
                if code == ENOSPC {
                    throw BiscuitError(
                        kind: .deviceTooSmall,
                        message: t(.errorNoSpaceLeft),
                        remedy: t(.errorNoSpaceLeftRemedy)
                    )
                }
                if code == EFBIG {
                    throw BiscuitError(
                        kind: .imageTooLarge,
                        message: t(.errorFileTooLargeForFilesystem, destination.lastPathComponent),
                        remedy: t(.errorFileTooLargeForFilesystemRemedy)
                    )
                }
                throw BiscuitError(
                    kind: .copyFailed,
                    message: t(.errorCopyWriteFailed, destination.lastPathComponent),
                    diagnostics: "write: errno \(code): \(String(cString: strerror(code)))"
                )
            }
            onChunk(UInt64(readCount))
        }
    }
}
