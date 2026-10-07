import Foundation

/// How a device is physically attached. Used to gate destructive operations.
public enum DeviceBus: String, Codable, Sendable, CaseIterable {
    case usb
    case thunderbolt
    case sdCard = "sd_card"
    case firewire
    case internalDrive = "internal"
    case virtual
    case unknown

    /// Buses we are willing to write to without an explicit override.
    public var isRemovableByDefault: Bool {
        switch self {
        case .usb, .sdCard, .firewire:
            return true
        case .thunderbolt, .internalDrive, .virtual, .unknown:
            return false
        }
    }

    public var displayName: String {
        switch self {
        case .usb: return t(.busUSB)
        case .thunderbolt: return t(.busThunderbolt)
        case .sdCard: return t(.busSDCard)
        case .firewire: return t(.busFireWire)
        case .internalDrive: return t(.busInternal)
        case .virtual: return t(.busVirtual)
        case .unknown: return t(.busUnknown)
        }
    }
}

/// A single mounted or mountable volume living on a `StorageDevice`.
public struct DeviceVolume: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }

    /// e.g. `disk4s1`
    public let bsdName: String
    public let name: String?
    public let mountPoint: String?
    public let filesystem: String?
    public let sizeBytes: UInt64

    public init(
        bsdName: String,
        name: String?,
        mountPoint: String?,
        filesystem: String?,
        sizeBytes: UInt64
    ) {
        self.bsdName = bsdName
        self.name = name
        self.mountPoint = mountPoint
        self.filesystem = filesystem
        self.sizeBytes = sizeBytes
    }
}

/// A whole physical disk. Never a partition.
public struct StorageDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: String { bsdName }

    /// e.g. `disk4`
    public let bsdName: String
    public let model: String
    public let vendor: String?
    public let sizeBytes: UInt64
    public let blockSize: UInt32
    public let bus: DeviceBus
    public let isRemovableMedia: Bool
    public let isEjectable: Bool
    public let isWritable: Bool
    /// True when the device backs the running system. Hard-blocked.
    public let isSystemDisk: Bool
    public let volumes: [DeviceVolume]

    public init(
        bsdName: String,
        model: String,
        vendor: String?,
        sizeBytes: UInt64,
        blockSize: UInt32,
        bus: DeviceBus,
        isRemovableMedia: Bool,
        isEjectable: Bool,
        isWritable: Bool,
        isSystemDisk: Bool,
        volumes: [DeviceVolume]
    ) {
        self.bsdName = bsdName
        self.model = model
        self.vendor = vendor
        self.sizeBytes = sizeBytes
        self.blockSize = blockSize
        self.bus = bus
        self.isRemovableMedia = isRemovableMedia
        self.isEjectable = isEjectable
        self.isWritable = isWritable
        self.isSystemDisk = isSystemDisk
        self.volumes = volumes
    }

    /// Buffered device node. Slow for bulk writes.
    public var devicePath: String { "/dev/\(bsdName)" }

    /// Unbuffered device node. Required for high-throughput raw writes.
    public var rawDevicePath: String { "/dev/r\(bsdName)" }

    public var displayName: String {
        let trimmedVendor = vendor?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedVendor, !trimmedVendor.isEmpty, !model.hasPrefix(trimmedVendor) {
            return "\(trimmedVendor) \(model)"
        }
        return model
    }

    /// Human-readable label for the volumes present, for the device list.
    public var volumeSummary: String? {
        let names = volumes.compactMap { volume -> String? in
            guard let name = volume.name, !name.isEmpty else { return nil }
            return name
        }
        guard !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }

    /// A device is offered in the UI only when it is plausibly a removable target.
    public var isEligibleTarget: Bool {
        guard !isSystemDisk, isWritable, sizeBytes > 0 else { return false }
        return bus.isRemovableByDefault || isRemovableMedia || isEjectable
    }

    /// Devices above this size are almost certainly not a USB stick; we warn loudly.
    public var exceedsPlausibleFlashSize: Bool {
        sizeBytes > 2 * 1024 * 1024 * 1024 * 1024 // 2 TiB
    }
}
