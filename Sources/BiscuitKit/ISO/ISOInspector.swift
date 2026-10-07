import Foundation

/// Determines what a user-supplied file actually is, and therefore which write
/// strategies are legal for it.
///
/// This matters for correctness, not convenience: writing a Windows ISO raw
/// produces a stick that silently fails to boot on UEFI, because Microsoft ships
/// those ISOs without a hybrid MBR. Rufus solves this by always doing a file
/// copy for Windows; we detect the case and refuse the wrong strategy outright.
public struct ISOInspector: Sendable {
    /// ISO 9660 places the Primary Volume Descriptor at logical sector 16.
    private static let sectorSize = 2048
    private static let pvdOffset = 16 * 2048

    private let mounter = DiskImageMounter()

    public init() {}

    // MARK: - Entry point

    public func inspect(_ url: URL) async throws -> MediaSource {
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorSourceMissing),
                diagnostics: url.path
            )
        }

        if url.pathExtension.lowercased() == "app" {
            return try inspectMacOSInstallerApp(url)
        }

        guard fm.isReadableFile(atPath: url.path) else {
            throw BiscuitError(
                kind: .sourceUnreadable,
                message: t(.errorSourceUnreadable),
                remedy: t(.errorSourceUnreadableRemedy),
                diagnostics: url.path
            )
        }

        let size = try fileSize(of: url)
        guard size >= 32 * 1024 else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorSourceTooSmall),
                diagnostics: "\(size) Bytes"
            )
        }

        let header = try readHeader(of: url, bytes: Self.pvdOffset + Self.sectorSize)
        let signature = BootSignature(header: header)
        let isoLabel = Self.iso9660VolumeLabel(from: header)

        // Only ISO/UDF images can carry a Windows installer tree, and only those
        // are worth the cost of mounting.
        if isoLabel != nil || signature.hasISO9660Magic {
            return try await inspectOpticalImage(
                url: url,
                size: size,
                isoLabel: isoLabel,
                signature: signature
            )
        }

        return inspectRawImage(
            url: url,
            size: size,
            signature: signature,
            format: CompressionFormat.detect(magic: header)
        )
    }

    // MARK: - Optical images (ISO / UDF)

    private func inspectOpticalImage(
        url: URL,
        size: UInt64,
        isoLabel: String?,
        signature: BootSignature
    ) async throws -> MediaSource {
        var notes: [String] = []
        if signature.hasHybridMBR { notes.append(t(.noteHybridMBR)) }
        if signature.hasGPTHeader { notes.append(t(.noteGPTHeader)) }

        let contents = try? await mounter.withReadOnlyMount(url) { attachment -> MountScan in
            guard let mountPoint = attachment.mountPoint else {
                throw BiscuitError(
                    kind: .mountFailed,
                    message: t(.errorImageUnmountable)
                )
            }
            return try Self.scan(mountPoint: mountPoint)
        }

        guard let contents else {
            // Unmountable but ISO-shaped: the only safe thing left is a raw copy,
            // and only if a boot sector is actually present.
            notes.append(t(.noteFilesystemUnreadable))
            return MediaSource(
                url: url,
                payload: signature.hasHybridMBR ? .hybridISO : .nonBootableISO,
                sizeBytes: size,
                volumeLabel: isoLabel,
                supportedStrategies: signature.hasHybridMBR ? [.rawImage] : [],
                detectionNotes: notes
            )
        }

        notes.append(contentsOf: contents.notes)

        if contents.isWindowsInstaller {
            return makeWindowsSource(
                url: url,
                size: size,
                isoLabel: isoLabel,
                scan: contents,
                notes: notes
            )
        }

        if signature.hasHybridMBR || contents.hasEFIBootLoader {
            if !signature.hasHybridMBR {
                notes.append(t(.noteUEFIOnly))
            }
            return MediaSource(
                url: url,
                payload: .hybridISO,
                sizeBytes: size,
                volumeLabel: isoLabel,
                supportedStrategies: [.rawImage],
                largestInnerFileBytes: contents.largestFileBytes,
                expandedSizeBytes: nil,
                detectionNotes: notes
            )
        }

        notes.append(t(.noteNoBootSector))
        return MediaSource(
            url: url,
            payload: .nonBootableISO,
            sizeBytes: size,
            volumeLabel: isoLabel,
            supportedStrategies: [],
            largestInnerFileBytes: contents.largestFileBytes,
            detectionNotes: notes
        )
    }

    private func makeWindowsSource(
        url: URL,
        size: UInt64,
        isoLabel: String?,
        scan: MountScan,
        notes: [String]
    ) -> MediaSource {
        var notes = notes
        let strategies: [WriteStrategy] = [.windowsFAT32]

        let fat32Limit = TargetFilesystem.fat32.maxFileSizeBytes ?? .max
        let oversized = scan.filesExceeding(fat32Limit)

        if oversized.isEmpty {
            notes.append(t(.noteFitsFAT32))
        } else {
            let names = oversized.map {
                "\($0.name) (\(ByteCount.format($0.sizeBytes)))"
            }.joined(separator: ", ")
            notes.append(t(.noteExceedsFAT32, names))
            let decision = Self.oversizeHandling(
                metadata: scan.windowsMetadata, oversized: oversized
            )
            notes.append(contentsOf: decision.notes)
        }

        if let metadata = scan.windowsMetadata {
            if let version = metadata.commonVersion {
                let generation = version.productGeneration ?? ""
                notes.append(t(.noteWindowsVersion, generation, version.displayName))
            }
            if let architecture = metadata.commonArchitecture {
                notes.append(t(.noteWindowsArchitecture, architecture.displayName))
                // The failure this exists to prevent: an ARM64 image written to
                // a stick for an ordinary desktop produces a medium that looks
                // finished and cannot boot, with nothing to explain why.
                if !architecture.isCommonPCArchitecture {
                    notes.append(t(.noteWindowsArchitectureUnusual, architecture.displayName))
                }
            }
            if !metadata.images.isEmpty {
                notes.append(
                    t(.noteWindowsEditions, metadata.images.map(\.name).joined(separator: ", "))
                )
            }
            let languages = metadata.allLanguages
            if !languages.isEmpty {
                notes.append(t(.noteWindowsLanguages, languages.joined(separator: ", ")))
            }
            // Writing one piece of a split set yields unusable media.
            if metadata.isSplit {
                notes.append(t(.noteWindowsSplitSet, metadata.partNumber, metadata.totalParts))
            }
        }

        return MediaSource(
            url: url,
            payload: .windowsInstaller,
            sizeBytes: size,
            volumeLabel: isoLabel ?? "WINDOWS",
            supportedStrategies: strategies,
            largestInnerFileBytes: scan.largestFileBytes,
            expandedSizeBytes: scan.totalBytes,
            detectionNotes: notes,
            windowsMetadata: scan.windowsMetadata
        )
    }

    /// How an oversized inner image will be made to fit FAT32.
    enum OversizeHandling: Equatable {
        case split
        case convert

        var notes: [String] {
            switch self {
            case .split: return [t(.noteWillSplitWIM)]
            case .convert: return [t(.noteWillConvertESD)]
            }
        }
    }

    /// Decides between splitting and converting.
    ///
    /// Extracted as a pure function so it can be tested: the branch only fires
    /// for inner files above 4 GiB, and building a 5 GB ISO fixture to reach it
    /// is not practical.
    ///
    /// The decision is made from the file's own contents, not its extension.
    /// The extension says nothing useful: a solid-compressed `install.wim`
    /// cannot be split either, and `wimlib-imagex split` refuses it with exit
    /// 68 — which, under the old extension-based guess, happened *after* the
    /// medium was already partly written. Measured against wimlib 1.14.5: a
    /// solid WIM and a non-solid LZMS WIM carry identical header flags, so only
    /// the blob-table descriptors settle it. See `WIMMetadata.canBeSplit`.
    ///
    /// With no metadata the extension is all that is left, and conversion is
    /// chosen for anything not plainly a `.wim`: a wrong "convert" costs time,
    /// a wrong "split" costs the job.
    static func oversizeHandling(
        metadata: WIMMetadata?,
        oversized: [MountScan.Entry]
    ) -> (handling: OversizeHandling, notes: [String]) {
        guard let metadata else {
            let byName = oversized.allSatisfy(\.isSplittableWIM)
            let handling: OversizeHandling = byName ? .split : .convert
            return (handling, handling.notes)
        }

        if metadata.canBeSplit {
            return (.split, OversizeHandling.split.notes)
        }

        var notes: [String] = []
        // Worth saying out loud: the file looks splittable by name and is not.
        if oversized.allSatisfy(\.isSplittableWIM) {
            notes.append(t(.noteSolidWIMCannotSplit, metadata.compression.displayName))
        }
        notes.append(contentsOf: OversizeHandling.convert.notes)
        return (.convert, notes)
    }

    // MARK: - Raw images

    private func inspectRawImage(
        url: URL,
        size: UInt64,
        signature: BootSignature,
        format: CompressionFormat
    ) -> MediaSource {
        var notes: [String] = []
        var strategies: [WriteStrategy] = [.rawImage]

        if signature.hasHybridMBR {
            notes.append(t(.noteHybridMBR))
        } else if signature.hasGPTHeader {
            notes.append(t(.noteGPTHeader))
        } else {
            notes.append(t(.noteNoPartitionTable))
        }

        if signature.looksCompressed {
            // Compressed images used to be refused outright, which pushed the
            // user into decompressing by hand — twice the disk space, and the
            // publisher's checksum no longer matches what they are about to
            // write. They are decompressed on the fly instead.
            if format.isSupported {
                notes.append(t(.noteCompressedSupported, format.displayName))
                if let expanded = Self.expandedSize(of: url, format: format) {
                    switch expanded {
                    case .exact(let size):
                        notes.append(t(.noteExpandsTo, ByteCount.format(size)))
                    case .approximate(let size, _):
                        notes.append(t(.noteExpandsToApproximately, ByteCount.format(size)))
                    case .unknown:
                        notes.append(t(.noteExpandedSizeUnknown))
                    }
                }
            } else {
                notes.append(t(.errorCompressionUnsupported, format.displayName))
                strategies = []
            }
        }

        return MediaSource(
            url: url,
            payload: .rawDiskImage,
            sizeBytes: size,
            volumeLabel: url.deletingPathExtension().lastPathComponent,
            supportedStrategies: strategies,
            // Drives the capacity check, so the *expanded* size is what counts.
            expandedSizeBytes: signature.looksCompressed
                ? Self.expandedSize(of: url, format: format)?.value
                : size,
            detectionNotes: notes
        )
    }

    /// Reads the expanded size out of the container's own metadata.
    private static func expandedSize(of url: URL, format: CompressionFormat) -> ExpandedSize? {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return ExpandedSizeReader.read(format: format, fileDescriptor: fd)
    }

    // MARK: - macOS installer app

    private func inspectMacOSInstallerApp(_ url: URL) throws -> MediaSource {
        let createInstallMedia = url
            .appendingPathComponent("Contents/Resources/createinstallmedia")

        guard FileManager.default.isExecutableFile(atPath: createInstallMedia.path) else {
            throw BiscuitError(
                kind: .sourceUnsupported,
                message: t(.errorNotAMacOSInstaller),
                remedy: t(.errorNotAMacOSInstallerRemedy),
                diagnostics: "createinstallmedia missing at \(createInstallMedia.path)"
            )
        }

        let bundle = Bundle(url: url)
        let version = bundle?.infoDictionary?["CFBundleShortVersionString"] as? String
        let name = bundle?.infoDictionary?["CFBundleDisplayName"] as? String
            ?? url.deletingPathExtension().lastPathComponent

        var notes = [t(.noteUsesCreateInstallMedia)]
        if let version { notes.append(t(.noteInstallerVersion, version)) }

        let size = (try? directorySize(of: url)) ?? 0

        return MediaSource(
            url: url,
            payload: .macOSInstallerApp,
            sizeBytes: size,
            volumeLabel: String(name.replacingOccurrences(of: "Install ", with: "").prefix(11)),
            supportedStrategies: [.macOSInstaller],
            expandedSizeBytes: max(size, .gibibytes(16)),
            detectionNotes: notes
        )
    }

    // MARK: - Low-level reads

    private func fileSize(of url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw BiscuitError.internalInconsistency("file size unavailable: \(url.path)")
        }
        return size.uint64Value
    }

    private func directorySize(of url: URL) throws -> UInt64 {
        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            total += UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    private func readHeader(of url: URL, bytes: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return (try handle.read(upToCount: bytes)) ?? Data()
    }

    /// Extracts the 32-byte, space-padded volume identifier from the PVD.
    static func iso9660VolumeLabel(from header: Data) -> String? {
        let descriptorStart = pvdOffset
        guard header.count >= descriptorStart + 72 else { return nil }
        let base = header.startIndex + descriptorStart

        // Byte 0 is the descriptor type (1 = primary), bytes 1…5 are "CD001".
        let magic = header[(base + 1)..<(base + 6)]
        guard String(decoding: magic, as: UTF8.self) == "CD001" else { return nil }
        guard header[base] == 0x01 else { return nil }

        let labelBytes = header[(base + 40)..<(base + 72)]
        let label = String(decoding: labelBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return label.isEmpty ? nil : label
    }
}

// MARK: - Boot signature probing

struct BootSignature: Sendable {
    let hasHybridMBR: Bool
    let hasGPTHeader: Bool
    let hasISO9660Magic: Bool
    let looksCompressed: Bool

    init(header: Data) {
        let bytes = [UInt8](header)

        // Classic MBR: 0x55 0xAA at offset 510, plus at least one partition
        // entry with a non-zero type byte in the 16-byte entries at 446…509.
        var hybrid = false
        if bytes.count > 512, bytes[510] == 0x55, bytes[511] == 0xAA {
            for entry in 0..<4 {
                let typeByte = bytes[446 + entry * 16 + 4]
                if typeByte != 0x00 { hybrid = true; break }
            }
        }
        hasHybridMBR = hybrid

        // GPT: "EFI PART" at the start of LBA 1.
        if bytes.count > 520 {
            hasGPTHeader = Array(bytes[512..<520]) == Array("EFI PART".utf8)
        } else {
            hasGPTHeader = false
        }

        // ISO 9660: "CD001" at 0x8001.
        if bytes.count > 32774 {
            hasISO9660Magic = Array(bytes[32769..<32774]) == Array("CD001".utf8)
        } else {
            hasISO9660Magic = false
        }

        // Writing a still-compressed image produces an unbootable stick, so this
        // is worth catching before the user wipes a drive.
        if bytes.count >= 6 {
            let prefix = Array(bytes[0..<6])
            let gzip: [UInt8] = [0x1F, 0x8B]
            let xz: [UInt8] = [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]
            let zstd: [UInt8] = [0x28, 0xB5, 0x2F, 0xFD]
            let bzip2: [UInt8] = [0x42, 0x5A, 0x68]
            let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04]
            looksCompressed = prefix.starts(with: gzip)
                || prefix.starts(with: xz)
                || prefix.starts(with: zstd)
                || prefix.starts(with: bzip2)
                || prefix.starts(with: zip)
        } else {
            looksCompressed = false
        }
    }
}

// MARK: - Mounted content scan

struct MountScan: Sendable {
    struct Entry: Sendable {
        let name: String
        let relativePath: String
        let sizeBytes: UInt64

        /// `install.wim` can be split into `install.swm` chunks that Windows
        /// Setup reads natively. `install.esd` cannot be split.
        var isSplittableWIM: Bool {
            name.lowercased().hasSuffix(".wim")
        }
    }

    let totalBytes: UInt64
    let largestFileBytes: UInt64
    let entries: [Entry]
    let isWindowsInstaller: Bool
    let hasEFIBootLoader: Bool
    let notes: [String]

    /// Read from `sources/install.wim` while the image was still mounted.
    ///
    /// Has to happen inside the mount scope: the mount point is gone by the
    /// time this value is returned, so deferring the read would mean reading
    /// from a path that no longer exists.
    let windowsMetadata: WIMMetadata?

    func filesExceeding(_ limit: UInt64) -> [Entry] {
        entries.filter { $0.sizeBytes > limit }
    }
}

extension ISOInspector {
    static func scan(mountPoint: URL) throws -> MountScan {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey, .isDirectoryKey]

        var total: UInt64 = 0
        var largest: UInt64 = 0
        var notable: [MountScan.Entry] = []
        var sawWindowsImage = false
        var sawBootmgr = false
        var sawEFILoader = false
        var fileCount = 0
        var windowsImagePath: URL?

        guard let enumerator = fm.enumerator(
            at: mountPoint,
            includingPropertiesForKeys: keys,
            options: []
        ) else {
            throw BiscuitError(
                kind: .mountFailed,
                message: t(.errorImageUnmountable)
            )
        }

        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let size = UInt64(values?.fileSize ?? 0)
            total += size
            largest = max(largest, size)
            fileCount += 1

            let relative = item.path.replacingOccurrences(of: mountPoint.path, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let lowerRelative = relative.lowercased()
            let lowerName = item.lastPathComponent.lowercased()

            if lowerRelative == "sources/install.wim" || lowerRelative == "sources/install.esd" {
                sawWindowsImage = true
                windowsImagePath = item
            }
            if lowerRelative == "bootmgr" || lowerRelative == "bootmgr.efi" {
                sawBootmgr = true
            }
            if lowerRelative == "efi/boot/bootx64.efi" || lowerRelative == "efi/boot/bootaa64.efi" {
                sawEFILoader = true
            }

            // Track every file above 1 GiB; those are the ones that decide the
            // FAT32 question. Keeping the list short avoids holding tens of
            // thousands of entries for a full Linux distribution.
            if size > .gibibytes(1) {
                notable.append(
                    MountScan.Entry(
                        name: item.lastPathComponent,
                        relativePath: relative,
                        sizeBytes: size
                    )
                )
            }
            _ = lowerName
        }

        var notes: [String] = []
        let isWindows = sawWindowsImage && (sawBootmgr || sawEFILoader)
        if sawWindowsImage && !isWindows {
            notes.append(t(.noteWindowsImageWithoutBootFiles))
        }
        notes.append(t(.noteContentSummary, fileCount, ByteCount.format(total)))

        // Read here, not later: the caller receives this value after the image
        // has been detached. A failure is not fatal — the medium can still be
        // built without knowing the edition list — so it degrades to `nil` with
        // a note rather than aborting the inspection.
        var metadata: WIMMetadata?
        if isWindows, let windowsImagePath {
            do {
                metadata = try WIMMetadata.read(from: windowsImagePath)
            } catch let error as BiscuitError {
                notes.append(error.message)
            } catch {
                notes.append(t(.errorWimMetadataUnreadable))
            }
        }

        return MountScan(
            totalBytes: total,
            largestFileBytes: largest,
            entries: notable,
            isWindowsInstaller: isWindows,
            hasEFIBootLoader: sawEFILoader,
            notes: notes,
            windowsMetadata: metadata
        )
    }
}
