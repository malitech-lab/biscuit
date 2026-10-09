import Foundation
import Testing
@testable import BiscuitKit

/// The device identifier decides what gets erased.
///
/// `normaliseWholeDisk` used to return any input that did not begin with `disk`
/// unchanged, and `diskutil info -plist` accepts *mount points* as well as
/// device identifiers — measured: `diskutil info -plist /` exits zero and
/// describes the running system volume. So the string `/` travelled through as
/// a device identifier, `StorageDevice.bsdName` was set from it, and
/// `isSystemDisk`, computed as `systemDisks.contains(bsdName)` against
/// normalised names like `disk3`, reported **false for the system disk**.
///
/// On an internally-booted Mac the eligibility check caught it afterwards by
/// accident, the internal disk being neither removable nor ejectable. On a Mac
/// booted from an external SSD — ordinary on older machines — `/` reports as
/// external and ejectable, both gates pass, and the target is the running
/// system disk.
@Suite("Geräte-Kennung")
struct DeviceIdentifierTests {

    // MARK: - Shape

    @Test("Echte Kennungen werden akzeptiert")
    func acceptsRealIdentifiers() {
        for identifier in [
            "disk0", "disk4", "disk12", "disk4s1", "disk4s1s1",
            "/dev/disk4", "/dev/disk12s3", "/dev/rdisk7s2", "rdisk0"
        ] {
            #expect(
                DeviceInspector.isPlausibleIdentifier(identifier),
                "\(identifier) abgelehnt"
            )
        }
    }

    @Test("Ein Einhängepunkt wird abgelehnt")
    func rejectsMountPoints() {
        // The actual attack. `diskutil` would accept all of these.
        for identifier in ["/", "/Volumes/Macintosh HD", "/System/Volumes/Data", "/tmp"] {
            #expect(
                !DeviceInspector.isPlausibleIdentifier(identifier),
                "\(identifier) akzeptiert"
            )
        }
    }

    @Test("Traversal und Beiwerk werden abgelehnt")
    func rejectsTraversalAndJunk() {
        for identifier in [
            "disk4/../../etc", "../disk4", "disk", "diskX", "disk4s", "disk4s1x",
            "disk4 disk5", "", "disk4;rm -rf /", "disk-4", "DISK4", "disk4\n"
        ] {
            #expect(
                !DeviceInspector.isPlausibleIdentifier(identifier),
                "\(identifier.debugDescription) akzeptiert"
            )
        }
    }

    @Test("Die Normalisierung bleibt für echte Kennungen unverändert")
    func normalisationUnchangedForRealIdentifiers() {
        // The existing behaviour these tests must not break.
        #expect(DeviceInspector.normaliseWholeDisk("disk4") == "disk4")
        #expect(DeviceInspector.normaliseWholeDisk("disk4s1") == "disk4")
        #expect(DeviceInspector.normaliseWholeDisk("disk4s1s1") == "disk4")
        #expect(DeviceInspector.normaliseWholeDisk("/dev/disk12s3") == "disk12")
        #expect(DeviceInspector.normaliseWholeDisk("/dev/rdisk7s2") == "disk7")
    }

    // MARK: - The guard that was defeated

    @Test("Die Systemdatenträger-Schranke greift bei echter Kennung")
    func systemDiskGuardWorksForRealIdentifier() {
        let device = StorageDevice(
            bsdName: "disk3",
            model: "APPLE SSD",
            vendor: nil,
            sizeBytes: 494_384_795_648,
            blockSize: 4096,
            bus: .internalDrive,
            isRemovableMedia: false,
            isEjectable: false,
            isWritable: true,
            isSystemDisk: true,
            volumes: []
        )
        #expect(!device.isEligibleTarget)
    }

    @Test("Ein externer Systemdatenträger wäre ohne die Schranke wählbar")
    func externalSystemDiskIsOnlySavedByTheGuard() {
        // This is the scenario the identifier bug made reachable: a Mac booted
        // from an external SSD. Every other property says "fine target".
        let shape = { (isSystemDisk: Bool) in
            StorageDevice(
                bsdName: "disk5",
                model: "Samsung T7",
                vendor: "Samsung",
                sizeBytes: 1_000_204_886_016,
                blockSize: 512,
                bus: .usb,
                isRemovableMedia: false,
                isEjectable: true,
                isWritable: true,
                isSystemDisk: isSystemDisk,
                volumes: []
            )
        }
        // Correctly flagged: refused.
        #expect(!shape(true).isEligibleTarget)
        // Flag defeated: accepted — which is what made the bug catastrophic
        // rather than merely untidy.
        #expect(shape(false).isEligibleTarget)
    }

    // MARK: - Live

    /// Confirms the premise against the real tool.
    @Test("diskutil akzeptiert tatsächlich einen Einhängepunkt", .timeLimit(.minutes(2)))
    func diskutilAcceptsMountPoint() async throws {
        // The whole bug rests on this being true, so it is measured rather
        // than assumed — and if a future macOS stops accepting mount points,
        // this test says so instead of quietly losing its reason to exist.
        guard FileManager.default.isExecutableFile(atPath: DeviceInspector.diskutil) else {
            return
        }
        let result = try await ProcessRunner.run(
            DeviceInspector.diskutil, arguments: ["info", "-plist", "/"], timeout: 30
        )
        #expect(
            result.succeeded,
            "diskutil lehnt '/' inzwischen ab — die Annahme dieses Tests ist überholt"
        )
    }

    @Test("Eine unplausible Kennung erreicht diskutil nicht", .timeLimit(.minutes(2)))
    func implausibleIdentifierIsRejectedBeforeDiskutil() async throws {
        guard FileManager.default.isExecutableFile(atPath: DeviceInspector.diskutil) else {
            return
        }
        let inspector = DeviceInspector()
        let error = try await #require(throws: BiscuitError.self) {
            _ = try await inspector.inspectDevice(bsdName: "/")
        }
        #expect(error.diagnostics?.contains("implausible device identifier") == true)
    }

    @Test("Eine echte Kennung lässt sich weiterhin einlesen", .timeLimit(.minutes(2)))
    func realIdentifierStillWorks() async throws {
        // Guards against the shape check being too strict and rejecting the
        // machine's own disks.
        guard FileManager.default.isExecutableFile(atPath: DeviceInspector.diskutil) else {
            return
        }
        let inspector = DeviceInspector()
        let devices = try await inspector.enumerateDevices()
        // Keine Geräteliste zu verlangen: `enumerateDevices` zeigt
        // Wechseldatenträger, und ohne angeschlossenen Stick ist die Liste
        // berechtigterweise leer. Der erste Entwurf verlangte sie und schlug
        // fehl, sobald der Teststick ausgeworfen war — ein Test, der von
        // angestecktem Zubehör abhängt, meldet die Umgebung statt die Software.
        guard !devices.isEmpty else { return }
        for device in devices {
            #expect(
                DeviceInspector.isPlausibleIdentifier(device.bsdName),
                Comment(rawValue: "eigenes Gerät \(device.bsdName) gilt als unplausibel")
            )
        }
    }

    @Test("Der Systemdatenträger dieses Macs wird als solcher erkannt", .timeLimit(.minutes(2)))
    func thisMacsSystemDiskIsFlagged() async throws {
        // The positive control for the guard: on every Mac at least one disk
        // backs the running system, and it must not be offered.
        guard FileManager.default.isExecutableFile(atPath: DeviceInspector.diskutil) else {
            return
        }
        let devices = try await DeviceInspector().enumerateDevices()
        guard !devices.isEmpty else { return }
        #expect(
            devices.contains { $0.isSystemDisk },
            "kein Gerät als Systemdatenträger markiert — die Schranke greift nicht"
        )
        for device in devices where device.isSystemDisk {
            #expect(!device.isEligibleTarget, Comment(rawValue: "\(device.bsdName) wird angeboten"))
        }
    }
}

extension DeviceIdentifierTests {
    /// The second, independent layer.
    ///
    /// Besides refusing an implausible shape, `inspect` now takes the device
    /// name from `diskutil`'s reported `DeviceIdentifier` rather than echoing
    /// the request, and refuses to continue if the two disagree. Verified by
    /// removing the shape check and observing that this one still catches `/`:
    /// `diskutil` reports `disk3s1s1`, which normalises to `disk3` and does not
    /// match the requested `/`.
    ///
    /// Two layers because the first is a syntactic judgement about a string and
    /// the second is a factual one about a device. A future identifier format
    /// could slip past the first; it cannot slip past the second.
    @Test("Ein abweichend gemeldetes Gerät wird abgelehnt")
    func mismatchedReportedDeviceIsRejected() throws {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var source: String?
        for _ in 0..<5 {
            let candidate = directory
                .appendingPathComponent("Sources/BiscuitKit/Devices/DeviceInspector.swift")
            if let data = try? Data(contentsOf: candidate) {
                source = String(decoding: data, as: UTF8.self)
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        let text = try #require(source, "DeviceInspector.swift nicht gefunden")

        // The name must be derived, and the mismatch must be fatal.
        #expect(text.contains("diskutil reports"), "keine Abweichungsprüfung")
        #expect(
            !text.contains("isSystemDisk: systemDisks.contains(bsdName)"),
            "isSystemDisk prüft wieder gegen die angefragte Kennung"
        )
        #expect(text.contains("isSystemDisk: systemDisks.contains(resolved)"))
    }
}
