import BiscuitKit
import Foundation

/// Turns a user-selected `MediaSource` into something the privileged helper is
/// allowed to touch, and cleans up afterwards.
///
/// All of the privacy-sensitive work happens here, in the unprivileged process
/// that actually holds the user's consent for the file they picked:
///
/// - raw images are opened here and handed over as a descriptor;
/// - ISOs are attached read-only here (`hdiutil` needs no privileges for that)
///   and handed over as a `/Volumes` path;
/// - installer bundles are only accepted from `/Applications`, which is outside
///   TCC's scope, because `createinstallmedia` must be executed by root from a
///   path.
@MainActor
final class SourcePreparer {
    /// A prepared source plus the teardown required once the job ends.
    ///
    /// Isolated to the main actor so that closing the descriptor and detaching
    /// the image happen on the same actor that created them; the teardown
    /// closure captures non-`Sendable` state deliberately.
    @MainActor
    struct Prepared {
        let handle: SourceHandle
        /// Open descriptor to transfer, if the handle calls for one.
        let descriptor: Int32?
        private let teardown: @MainActor () async -> Void

        init(
            handle: SourceHandle,
            descriptor: Int32?,
            teardown: @escaping @MainActor () async -> Void
        ) {
            self.handle = handle
            self.descriptor = descriptor
            self.teardown = teardown
        }

        /// Idempotent in practice: closing an already-closed descriptor is
        /// guarded by the caller, and `hdiutil detach` on a detached image is a
        /// no-op that we deliberately ignore.
        func release() async {
            await teardown()
        }
    }

    private let mounter = DiskImageMounter()

    func prepare(
        source: MediaSource?,
        strategy: WriteStrategy
    ) async throws -> Prepared {
        switch strategy {
        case .eraseOnly:
            return Prepared(handle: .none, descriptor: nil, teardown: {})

        case .rawImage:
            guard let source else {
                throw BiscuitError.internalInconsistency("source missing for rawImage")
            }
            return try prepareDescriptor(for: source)

        case .windowsFAT32:
            guard let source else {
                throw BiscuitError.internalInconsistency("source missing for windowsFAT32")
            }
            return try await prepareMount(for: source)

        case .macOSInstaller:
            guard let source else {
                throw BiscuitError.internalInconsistency("source missing for macOSInstaller")
            }
            return try prepareInstallerBundle(for: source)
        }
    }

    // MARK: - Raw descriptor

    private func prepareDescriptor(for source: MediaSource) throws -> Prepared {
        let descriptor = open(source.url.path, O_RDONLY)
        guard descriptor >= 0 else {
            let code = errno
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorSourceOpenDenied),
                remedy: code == EPERM || code == EACCES
                    ? t(.errorSourceOpenDeniedRemedy)
                    : t(.errorSourceGoneRemedy),
                diagnostics: "open(\(source.url.path)): errno \(code): \(String(cString: strerror(code)))"
            )
        }

        // Re-stat through the descriptor: the size that reaches the helper must
        // describe the inode we actually opened, not whatever the path pointed at
        // during inspection.
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor)
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorSourceNotRegularFile)
            )
        }

        return Prepared(
            handle: .transferredDescriptor(
                sizeBytes: UInt64(info.st_size),
                displayName: source.url.lastPathComponent
            ),
            descriptor: descriptor,
            teardown: { close(descriptor) }
        )
    }

    // MARK: - Read-only mount

    private func prepareMount(for source: MediaSource) async throws -> Prepared {
        let attachment = try await mounter.attachReadOnly(source.url)
        guard let mountPoint = attachment.mountPoint else {
            await mounter.detach(attachment)
            throw BiscuitError(
                kind: .mountFailed,
                message: t(.errorImageNoFilesystem)
            )
        }

        let handle = SourceHandle.mountedDirectory(
            path: mountPoint.path,
            displayName: source.url.lastPathComponent
        )
        do {
            try handle.validatePath()
        } catch {
            await mounter.detach(attachment)
            throw error
        }

        let mounter = self.mounter
        return Prepared(
            handle: handle,
            descriptor: nil,
            teardown: { await mounter.detach(attachment) }
        )
    }

    // MARK: - Installer bundle

    private func prepareInstallerBundle(for source: MediaSource) throws -> Prepared {
        let path = source.url.standardizedFileURL.path
        let handle = SourceHandle.applicationBundle(path: path)

        do {
            try handle.validatePath()
        } catch {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorInstallerOutsideApplications),
                remedy: t(.errorInstallerOutsideApplicationsRemedy, source.url.lastPathComponent),
                diagnostics: path
            )
        }

        return Prepared(handle: handle, descriptor: nil, teardown: {})
    }
}
