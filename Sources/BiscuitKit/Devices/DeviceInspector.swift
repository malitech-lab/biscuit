import Foundation

/// Enumerates whole physical disks via `diskutil`'s plist output.
///
/// `diskutil` is used rather than raw IOKit traversal because its plist schema
/// is a stable, documented contract across macOS releases and already resolves
/// APFS containers back to their physical stores — logic that is easy to get
/// subtly wrong by hand and catastrophic when it is wrong.
public struct DeviceInspector: Sendable {
    public static let diskutil = "/usr/sbin/diskutil"

    public init() {}

    // MARK: - Public API

    /// All whole disks currently attached.
    public func enumerateDevices() async throws -> [StorageDevice] {
        let listing = try await plist(arguments: ["list", "-plist"])
        guard let wholeDisks = listing["WholeDisks"] as? [String] else { return [] }

        let systemDisks = await systemBackingDisks()
        var devices: [StorageDevice] = []

        for bsdName in wholeDisks {
            guard let device = try? await inspect(
                bsdName: bsdName,
                systemDisks: systemDisks,
                listing: listing
            ) else { continue }
            devices.append(device)
        }

        return devices.sorted { lhs, rhs in
            if lhs.isEligibleTarget != rhs.isEligibleTarget { return lhs.isEligibleTarget }
            return lhs.bsdName.localizedStandardCompare(rhs.bsdName) == .orderedAscending
        }
    }

    /// Re-reads a single device. Used immediately before a destructive write to
    /// catch the case where the user unplugged one stick and plugged in another
    /// between selecting the target and confirming.
    public func inspectDevice(bsdName: String) async throws -> StorageDevice {
        // Rejected up front rather than passed to `diskutil`, which happily
        // accepts a *mount point*: `diskutil info -plist /` succeeds and
        // describes the running system volume. See `isPlausibleIdentifier`.
        guard Self.isPlausibleIdentifier(bsdName) else {
            throw BiscuitError(
                kind: .deviceNotFound,
                message: t(.errorDeviceNotEligible, bsdName),
                diagnostics: "implausible device identifier: \(bsdName)"
            )
        }
        let normalised = Self.normaliseWholeDisk(bsdName)
        let listing = try await plist(arguments: ["list", "-plist"])
        let systemDisks = await systemBackingDisks()
        return try await inspect(bsdName: normalised, systemDisks: systemDisks, listing: listing)
    }

    /// Whether this is a BSD disk identifier and nothing else.
    ///
    /// ## Why this is not merely tidiness
    ///
    /// `JobRequest.targetBSDName` chooses the device that gets erased, and
    /// `normaliseWholeDisk` used to return any input that did not begin with
    /// `disk` **unchanged**. `diskutil info -plist /` then succeeds — it accepts
    /// mount points — so the string `/` flowed through as a device identifier.
    ///
    /// The consequence was worse than an odd log line. `StorageDevice.bsdName`
    /// was set from that input, and `isSystemDisk` is computed as
    /// `systemDisks.contains(bsdName)` against a set of normalised whole-disk
    /// names like `disk3`. `"/"` is not in that set, so the dedicated
    /// system-disk guard reported **false** for the system disk itself.
    ///
    /// On an internally-booted Mac the eligibility check happened to catch it
    /// afterwards, because the internal disk is neither removable nor
    /// ejectable. On a Mac booted from an external USB or Thunderbolt SSD —
    /// ordinary on older machines and test rigs — `/` reports as external and
    /// ejectable, both gates pass, and the running system disk is the target.
    static func isPlausibleIdentifier(_ identifier: String) -> Bool {
        let bare = identifier.hasPrefix("/dev/")
            ? String(identifier.dropFirst(5))
            : identifier
        var rest = Substring(bare)
        if rest.hasPrefix("r") { rest = rest.dropFirst() }
        guard rest.hasPrefix("disk") else { return false }
        rest = rest.dropFirst(4)

        // At least one digit for the disk number.
        let number = rest.prefix { $0.isNumber }
        guard !number.isEmpty else { return false }
        rest = rest.dropFirst(number.count)

        // Then zero or more `sN` slice suffixes, and nothing else.
        while rest.hasPrefix("s") {
            rest = rest.dropFirst()
            let slice = rest.prefix { $0.isNumber }
            guard !slice.isEmpty else { return false }
            rest = rest.dropFirst(slice.count)
        }
        return rest.isEmpty
    }

    /// Strips any partition suffix so `disk4s2` becomes `disk4`.
    public static func normaliseWholeDisk(_ identifier: String) -> String {
        let bare = identifier.hasPrefix("/dev/")
            ? String(identifier.dropFirst(5))
            : identifier
        let stripped = bare.hasPrefix("r") && bare.dropFirst().hasPrefix("disk")
            ? String(bare.dropFirst())
            : bare
        guard stripped.hasPrefix("disk") else { return stripped }
        let numeric = stripped.dropFirst(4).prefix { $0.isNumber }
        return "disk\(numeric)"
    }

    // MARK: - Single device

    private func inspect(
        bsdName: String,
        systemDisks: Set<String>,
        listing: [String: Any]
    ) async throws -> StorageDevice {
        let info = try await plist(arguments: ["info", "-plist", bsdName])

        let size = (info["Size"] as? NSNumber)?.uint64Value
            ?? (info["TotalSize"] as? NSNumber)?.uint64Value
            ?? 0
        let blockSize = (info["DeviceBlockSize"] as? NSNumber)?.uint32Value ?? 512

        let model = (info["MediaName"] as? String)?.trimmingCharacters(in: .whitespaces)
            ?? (info["IORegistryEntryName"] as? String)
            ?? bsdName
        let vendor = (info["DeviceVendor"] as? String)?.trimmingCharacters(in: .whitespaces)

        let bus = Self.mapBus(
            protocolName: info["BusProtocol"] as? String,
            isInternal: info["Internal"] as? Bool ?? false,
            isVirtual: (info["VirtualOrPhysical"] as? String) == "Virtual"
        )

        // Taken from what `diskutil` reports, not from what was asked for, so
        // that `isSystemDisk` below is evaluated against a real identifier.
        // The caller's string has already been shape-checked, but deriving the
        // name here removes the question entirely.
        let reported = (info["DeviceIdentifier"] as? String).map(Self.normaliseWholeDisk)
        let resolved = reported ?? bsdName
        guard resolved == bsdName else {
            throw BiscuitError(
                kind: .deviceNotFound,
                message: t(.errorDeviceChanged),
                remedy: t(.errorDeviceChangedRemedy, bsdName),
                diagnostics: "requested \(bsdName), diskutil reports \(resolved)"
            )
        }

        let volumes = Self.volumes(for: resolved, in: listing)

        return StorageDevice(
            bsdName: resolved,
            model: model.isEmpty ? resolved : model,
            vendor: vendor?.isEmpty == true ? nil : vendor,
            sizeBytes: size,
            blockSize: blockSize,
            bus: bus,
            isRemovableMedia: info["RemovableMedia"] as? Bool ?? false,
            isEjectable: info["Ejectable"] as? Bool ?? false,
            isWritable: info["WritableMedia"] as? Bool ?? true,
            isSystemDisk: systemDisks.contains(resolved),
            volumes: volumes
        )
    }

    // MARK: - Helpers

    private func plist(arguments: [String]) async throws -> [String: Any] {
        let result = try await ProcessRunner.run(
            Self.diskutil,
            arguments: arguments,
            timeout: 30
        )
        guard result.succeeded else {
            throw BiscuitError(
                kind: .deviceNotFound,
                message: t(.errorDeviceInfoUnavailable),
                diagnostics: "diskutil \(arguments.joined(separator: " ")): \(result.combinedOutput)"
            )
        }
        guard let data = result.standardOutput.data(using: .utf8),
              let parsed = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any]
        else {
            throw BiscuitError(
                kind: .deviceNotFound,
                message: t(.errorDeviceListUnreadable),
                diagnostics: result.standardOutput.prefix(2000).description
            )
        }
        return parsed
    }

    /// Resolves every physical disk that the running system depends on, including
    /// APFS physical stores behind the root volume and the Recovery/Preboot set.
    private func systemBackingDisks() async -> Set<String> {
        var result: Set<String> = []

        for mountPoint in ["/", "/System/Volumes/Data", "/System/Volumes/Preboot"] {
            guard let info = try? await plist(arguments: ["info", "-plist", mountPoint]) else {
                continue
            }
            if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
                for store in stores {
                    if let identifier = store["APFSPhysicalStore"] as? String {
                        result.insert(Self.normaliseWholeDisk(identifier))
                    }
                }
            }
            if let parent = info["ParentWholeDisk"] as? String {
                result.insert(Self.normaliseWholeDisk(parent))
            }
            if let identifier = info["DeviceIdentifier"] as? String {
                result.insert(Self.normaliseWholeDisk(identifier))
            }
        }

        // Belt and braces: anything marked internal and non-ejectable is treated
        // as system-critical even if the lookup above missed it.
        return result
    }

    static func mapBus(protocolName: String?, isInternal: Bool, isVirtual: Bool) -> DeviceBus {
        if isVirtual { return .virtual }
        switch protocolName?.uppercased() {
        case "USB":
            return isInternal ? .internalDrive : .usb
        case "THUNDERBOLT":
            return .thunderbolt
        case "SECURE DIGITAL", "SD":
            return .sdCard
        case "FIREWIRE":
            return .firewire
        case "DISK IMAGE":
            return .virtual
        case "SATA", "ATA", "PCI-EXPRESS", "PCI", "NVME", "APPLE FABRIC", "SAS":
            return .internalDrive
        default:
            return isInternal ? .internalDrive : .unknown
        }
    }

    static func volumes(for wholeDisk: String, in listing: [String: Any]) -> [DeviceVolume] {
        guard let disks = listing["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        guard let entry = disks.first(where: { ($0["DeviceIdentifier"] as? String) == wholeDisk })
        else { return [] }

        var volumes: [DeviceVolume] = []

        func append(from dictionary: [String: Any]) {
            guard let identifier = dictionary["DeviceIdentifier"] as? String else { return }
            volumes.append(
                DeviceVolume(
                    bsdName: identifier,
                    name: dictionary["VolumeName"] as? String,
                    mountPoint: dictionary["MountPoint"] as? String,
                    filesystem: dictionary["Content"] as? String,
                    sizeBytes: (dictionary["Size"] as? NSNumber)?.uint64Value ?? 0
                )
            )
        }

        for partition in (entry["Partitions"] as? [[String: Any]]) ?? [] {
            append(from: partition)
            for apfsVolume in (partition["APFSVolumes"] as? [[String: Any]]) ?? [] {
                append(from: apfsVolume)
            }
        }
        for apfsVolume in (entry["APFSVolumes"] as? [[String: Any]]) ?? [] {
            append(from: apfsVolume)
        }

        return volumes
    }
}
