import Foundation

/// What kind of payload a disc image carries. Drives which write strategy is legal.
public enum ImagePayload: String, Codable, Sendable {
    /// ISO 9660 / UDF hybrid image with an embedded MBR or isohybrid boot sector.
    /// Safe to write byte-for-byte (`dd` style).
    case hybridISO = "hybrid_iso"

    /// A Windows installation ISO. Must NOT be written raw — Windows ISOs carry
    /// no hybrid boot sector, so a raw copy does not boot on UEFI. Requires the
    /// file-copy strategy onto a FAT32 (or FAT32+exFAT) layout.
    case windowsInstaller = "windows_installer"

    /// Raw disk image (`.img`, `.dmg` UDIF read-only, Raspberry Pi images, …).
    case rawDiskImage = "raw_disk_image"

    /// A mounted macOS `Install macOS *.app` bundle.
    case macOSInstallerApp = "macos_installer_app"

    /// Recognised as an ISO but with no detectable boot path.
    case nonBootableISO = "non_bootable_iso"

    public var displayName: String {
        switch self {
        case .hybridISO: return t(.payloadHybridISO)
        case .windowsInstaller: return t(.payloadWindowsInstaller)
        case .rawDiskImage: return t(.payloadRawDiskImage)
        case .macOSInstallerApp: return t(.payloadMacOSInstaller)
        case .nonBootableISO: return t(.payloadNonBootableISO)
        }
    }
}

/// The strategy used to put a source onto a target device.
public enum WriteStrategy: String, Codable, Sendable, CaseIterable {
    /// Byte-for-byte block copy to `/dev/rdiskN`.
    case rawImage = "raw_image"

    /// Partition target as GPT+FAT32, mount, copy ISO contents, split `install.wim`
    /// into `install.swm` chunks below the FAT32 4 GiB file limit.
    ///
    /// This is the only Windows strategy offered, deliberately. The obvious
    /// alternative — a tiny FAT32 boot partition plus an exFAT data partition —
    /// does not work: UEFI firmware cannot read exFAT, and Windows Setup looks
    /// for `sources\install.wim` on the volume it booted from. Rufus solves the
    /// >4 GiB case with an NTFS partition plus its UEFI:NTFS driver shim, which
    /// is not reproducible here because macOS cannot write NTFS.
    case windowsFAT32 = "windows_fat32"

    /// Delegate to Apple's `createinstallmedia`.
    case macOSInstaller = "macos_installer"

    /// Erase only — produce a clean, empty, cross-platform usable stick.
    case eraseOnly = "erase_only"

    public var displayName: String {
        switch self {
        case .rawImage: return t(.strategyRawImage)
        case .windowsFAT32: return t(.strategyWindowsFAT32)
        case .macOSInstaller: return t(.strategyMacOSInstaller)
        case .eraseOnly: return t(.strategyEraseOnly)
        }
    }

    public var explanation: String {
        switch self {
        case .rawImage: return t(.strategyRawImageDetail)
        case .windowsFAT32: return t(.strategyWindowsFAT32Detail)
        case .macOSInstaller: return t(.strategyMacOSInstallerDetail)
        case .eraseOnly: return t(.strategyEraseOnlyDetail)
        }
    }
}

/// Partition scheme for erase/format operations.
public enum PartitionScheme: String, Codable, Sendable, CaseIterable {
    case gpt = "GPT"
    case mbr = "MBR"

    public var diskutilValue: String {
        switch self {
        case .gpt: return "GPT"
        case .mbr: return "MBR"
        }
    }

    public var displayName: String {
        switch self {
        case .gpt: return t(.schemeGPT)
        case .mbr: return t(.schemeMBR)
        }
    }
}

/// Filesystem for erase/format operations.
public enum TargetFilesystem: String, Codable, Sendable, CaseIterable {
    case fat32 = "FAT32"
    case exfat = "ExFAT"
    case hfsPlus = "JHFS+"
    case apfs = "APFS"

    public var diskutilValue: String { rawValue }

    public var displayName: String {
        switch self {
        case .fat32: return t(.filesystemFAT32)
        case .exfat: return t(.filesystemExFAT)
        case .hfsPlus: return t(.filesystemHFSPlus)
        case .apfs: return t(.filesystemAPFS)
        }
    }

    public var maxFileSizeBytes: UInt64? {
        switch self {
        case .fat32: return 4 * 1024 * 1024 * 1024 - 1
        case .exfat, .hfsPlus, .apfs: return nil
        }
    }
}

/// A validated, inspected source image ready to be written.
public struct MediaSource: Codable, Sendable, Hashable {
    public let url: URL
    public let payload: ImagePayload
    public let sizeBytes: UInt64
    public let volumeLabel: String?
    /// Strategies that are technically valid for this source, best first.
    public let supportedStrategies: [WriteStrategy]
    /// Largest single file inside the image, when known (drives FAT32 decisions).
    public let largestInnerFileBytes: UInt64?
    /// Total bytes of the extracted contents, when known.
    public let expandedSizeBytes: UInt64?
    public let detectionNotes: [String]

    /// Editions, languages, version and architecture, when the source is a
    /// Windows installer whose `install.wim` could be read.
    public let windowsMetadata: WIMMetadata?

    public init(
        url: URL,
        payload: ImagePayload,
        sizeBytes: UInt64,
        volumeLabel: String?,
        supportedStrategies: [WriteStrategy],
        largestInnerFileBytes: UInt64? = nil,
        expandedSizeBytes: UInt64? = nil,
        detectionNotes: [String] = [],
        windowsMetadata: WIMMetadata? = nil
    ) {
        self.url = url
        self.payload = payload
        self.sizeBytes = sizeBytes
        self.volumeLabel = volumeLabel
        self.supportedStrategies = supportedStrategies
        self.largestInnerFileBytes = largestInnerFileBytes
        self.expandedSizeBytes = expandedSizeBytes
        self.detectionNotes = detectionNotes
        self.windowsMetadata = windowsMetadata
    }

    public var recommendedStrategy: WriteStrategy? { supportedStrategies.first }

    /// Minimum target capacity, including slack for filesystem overhead.
    public var requiredCapacityBytes: UInt64 {
        let payloadBytes = expandedSizeBytes ?? sizeBytes
        // 3 % slack, floor 64 MiB, for FAT/exFAT metadata and alignment.
        let slack = max(UInt64(Double(payloadBytes) * 0.03), .mebibytes(64))
        return payloadBytes + slack
    }
}
