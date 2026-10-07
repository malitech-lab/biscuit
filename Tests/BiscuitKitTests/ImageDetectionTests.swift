import Foundation
import Testing
@testable import BiscuitKit

/// Boot-signature detection decides whether an image may be written raw.
/// Getting it wrong in the permissive direction produces a stick that does not
/// boot; getting it wrong in the restrictive direction blocks a legitimate ISO.
@Suite("Bootsektor-Erkennung")
struct BootSignatureTests {
    /// Builds a synthetic header large enough to contain the ISO 9660 PVD.
    private func makeHeader(
        mbrSignature: Bool = false,
        partitionType: UInt8 = 0,
        gpt: Bool = false,
        iso9660: Bool = false,
        compressionMagic: [UInt8] = [],
        volumeLabel: String? = nil
    ) -> Data {
        var bytes = [UInt8](repeating: 0, count: 16 * 2048 + 2048)

        for (index, byte) in compressionMagic.enumerated() {
            bytes[index] = byte
        }

        if mbrSignature {
            bytes[510] = 0x55
            bytes[511] = 0xAA
            // First partition entry's type byte lives at 446 + 4.
            bytes[446 + 4] = partitionType
        }

        if gpt {
            for (index, byte) in Array("EFI PART".utf8).enumerated() {
                bytes[512 + index] = byte
            }
        }

        if iso9660 {
            let base = 16 * 2048
            bytes[base] = 0x01 // primary volume descriptor
            for (index, byte) in Array("CD001".utf8).enumerated() {
                bytes[base + 1 + index] = byte
            }
            // Volume identifier is 32 space-padded bytes at offset 40.
            let padded = (volumeLabel ?? "").padding(
                toLength: 32,
                withPad: " ",
                startingAt: 0
            )
            for (index, byte) in Array(padded.utf8).prefix(32).enumerated() {
                bytes[base + 40 + index] = byte
            }
        }

        return Data(bytes)
    }

    @Test("Hybrider MBR erfordert Signatur und einen belegten Partitionstyp")
    func hybridMBR() {
        // 0x55AA alone is not enough: Windows ISOs carry a stub boot sector with
        // an all-zero partition table, and treating that as hybrid is exactly
        // the mistake that yields an unbootable stick.
        let signatureOnly = BootSignature(header: makeHeader(mbrSignature: true, partitionType: 0))
        #expect(!signatureOnly.hasHybridMBR)

        let realHybrid = BootSignature(header: makeHeader(mbrSignature: true, partitionType: 0x83))
        #expect(realHybrid.hasHybridMBR)

        let none = BootSignature(header: makeHeader())
        #expect(!none.hasHybridMBR)
    }

    @Test("GPT-Header wird erkannt")
    func gptHeader() {
        #expect(BootSignature(header: makeHeader(gpt: true)).hasGPTHeader)
        #expect(!BootSignature(header: makeHeader()).hasGPTHeader)
    }

    @Test("ISO-9660-Magic wird erkannt")
    func isoMagic() {
        #expect(BootSignature(header: makeHeader(iso9660: true)).hasISO9660Magic)
        #expect(!BootSignature(header: makeHeader()).hasISO9660Magic)
    }

    @Test("Komprimierte Abbilder werden vor dem Schreiben erkannt")
    func compressedImages() {
        let cases: [(String, [UInt8])] = [
            ("gzip", [0x1F, 0x8B, 0x08, 0x00, 0x00, 0x00]),
            ("xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]),
            ("zstd", [0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x00]),
            ("bzip2", [0x42, 0x5A, 0x68, 0x39, 0x00, 0x00]),
            ("zip", [0x50, 0x4B, 0x03, 0x04, 0x00, 0x00])
        ]
        for (name, magic) in cases {
            let signature = BootSignature(header: makeHeader(compressionMagic: magic))
            #expect(signature.looksCompressed, "\(name) hätte erkannt werden müssen")
        }
        #expect(!BootSignature(header: makeHeader()).looksCompressed)
    }

    @Test("Kurze Header führen nicht zum Absturz")
    func shortHeaderIsSafe() {
        for length in [0, 1, 16, 511, 512, 513, 32768] {
            let signature = BootSignature(header: Data(repeating: 0, count: length))
            #expect(!signature.hasHybridMBR)
            #expect(!signature.hasISO9660Magic)
        }
    }

    @Test("Volume-Label wird aus dem PVD gelesen und getrimmt")
    func volumeLabel() {
        let header = makeHeader(iso9660: true, volumeLabel: "UBUNTU_24_04")
        #expect(ISOInspector.iso9660VolumeLabel(from: header) == "UBUNTU_24_04")

        let empty = makeHeader(iso9660: true, volumeLabel: "")
        #expect(ISOInspector.iso9660VolumeLabel(from: empty) == nil)

        let notISO = makeHeader()
        #expect(ISOInspector.iso9660VolumeLabel(from: notISO) == nil)
    }
}

@Suite("Quellen-Pfad-Freigabe")
struct SourceHandleTests {
    @Test("Erlaubte Präfixe passieren")
    func allowedPaths() throws {
        try SourceHandle.mountedDirectory(path: "/Volumes/CCCOMA_X64FRE", displayName: "iso")
            .validatePath()
        try SourceHandle.applicationBundle(path: "/Applications/Install macOS Sequoia.app")
            .validatePath()
        try SourceHandle.none.validatePath()
        try SourceHandle.transferredDescriptor(sizeBytes: 1, displayName: "x").validatePath()
    }

    @Test("Benutzerverzeichnisse werden abgelehnt")
    func rejectedPaths() {
        // The helper runs as root. Holding the session token must not be enough
        // to point it at an arbitrary path, so this is enforced rather than
        // assumed.
        let rejected = [
            "/Users/mark/Downloads/win11.iso",
            "/etc/passwd",
            "/private/etc/sudoers",
            "/tmp/evil",
            "/Library/LaunchDaemons"
        ]
        for path in rejected {
            #expect(throws: BiscuitError.self) {
                try SourceHandle.mountedDirectory(path: path, displayName: "x").validatePath()
            }
        }
    }

    @Test("Traversal über ein erlaubtes Präfix wird abgelehnt")
    func rejectsTraversal() {
        #expect(throws: BiscuitError.self) {
            try SourceHandle
                .mountedDirectory(path: "/Volumes/../etc/passwd", displayName: "x")
                .validatePath()
        }
        #expect(throws: BiscuitError.self) {
            try SourceHandle
                .applicationBundle(path: "/Applications/../../etc")
                .validatePath()
        }
    }
}

@Suite("Kapazitätsberechnung")
struct MediaSourceTests {
    private func makeSource(
        size: UInt64,
        expanded: UInt64? = nil
    ) -> MediaSource {
        MediaSource(
            url: URL(fileURLWithPath: "/tmp/test.iso"),
            payload: .hybridISO,
            sizeBytes: size,
            volumeLabel: "TEST",
            supportedStrategies: [.rawImage],
            expandedSizeBytes: expanded
        )
    }

    @Test("Benötigte Kapazität enthält Reserve für Dateisystem-Overhead")
    func requiredCapacityHasSlack() {
        let source = makeSource(size: .gibibytes(4))
        #expect(source.requiredCapacityBytes > source.sizeBytes)
        // 3 % slack on 4 GiB is ~123 MiB, comfortably above the 64 MiB floor.
        #expect(source.requiredCapacityBytes < source.sizeBytes + .mebibytes(200))
    }

    @Test("Kleine Abbilder erhalten eine Mindestreserve")
    func smallImagesGetFloor() {
        let source = makeSource(size: .mebibytes(10))
        #expect(source.requiredCapacityBytes >= .mebibytes(10) + .mebibytes(64))
    }

    @Test("Entpackte Größe hat Vorrang vor der Dateigröße")
    func expandedSizeWins() {
        let source = makeSource(size: .gibibytes(1), expanded: .gibibytes(6))
        #expect(source.requiredCapacityBytes > .gibibytes(6))
    }
}

@Suite("Geräte-Eignung")
struct StorageDeviceTests {
    private func makeDevice(
        bus: DeviceBus,
        removable: Bool = true,
        ejectable: Bool = true,
        writable: Bool = true,
        system: Bool = false,
        size: UInt64 = .gibibytes(32)
    ) -> StorageDevice {
        StorageDevice(
            bsdName: "disk9",
            model: "Test",
            vendor: nil,
            sizeBytes: size,
            blockSize: 512,
            bus: bus,
            isRemovableMedia: removable,
            isEjectable: ejectable,
            isWritable: writable,
            isSystemDisk: system,
            volumes: []
        )
    }

    @Test("Systemdatenträger sind niemals zulässig")
    func systemDiskBlocked() {
        #expect(!makeDevice(bus: .usb, system: true).isEligibleTarget)
    }

    @Test("Schreibgeschützte Datenträger sind nicht zulässig")
    func readOnlyBlocked() {
        #expect(!makeDevice(bus: .usb, writable: false).isEligibleTarget)
    }

    @Test("Interne Datenträger sind standardmäßig gesperrt")
    func internalBlocked() {
        #expect(
            !makeDevice(bus: .internalDrive, removable: false, ejectable: false)
                .isEligibleTarget
        )
    }

    @Test("USB und SD sind zulässig")
    func removableAllowed() {
        #expect(makeDevice(bus: .usb).isEligibleTarget)
        #expect(makeDevice(bus: .sdCard).isEligibleTarget)
    }

    @Test("Thunderbolt gilt nur als zulässig, wenn es sich als wechselbar meldet")
    func thunderboltConservative() {
        // A Thunderbolt enclosure is usually someone's backup array, so the bus
        // alone does not qualify.
        #expect(
            !makeDevice(bus: .thunderbolt, removable: false, ejectable: false)
                .isEligibleTarget
        )
        #expect(makeDevice(bus: .thunderbolt, removable: true).isEligibleTarget)
    }

    @Test("Datenträger ohne Medium sind nicht zulässig")
    func emptyReaderBlocked() {
        #expect(!makeDevice(bus: .sdCard, size: 0).isEligibleTarget)
    }

    @Test("Rohe und gepufferte Gerätepfade")
    func devicePaths() {
        let device = makeDevice(bus: .usb)
        #expect(device.devicePath == "/dev/disk9")
        #expect(device.rawDevicePath == "/dev/rdisk9")
    }

    @Test("Sehr große Datenträger werden markiert")
    func implausibleSizeFlagged() {
        #expect(makeDevice(bus: .usb, size: .gibibytes(4000)).exceedsPlausibleFlashSize)
        #expect(!makeDevice(bus: .usb, size: .gibibytes(64)).exceedsPlausibleFlashSize)
    }
}

@Suite("BSD-Namen normalisieren")
struct DeviceInspectorTests {
    @Test("Partitionen werden auf die ganze Platte reduziert")
    func normalisation() {
        #expect(DeviceInspector.normaliseWholeDisk("disk4") == "disk4")
        #expect(DeviceInspector.normaliseWholeDisk("disk4s1") == "disk4")
        #expect(DeviceInspector.normaliseWholeDisk("disk4s1s1") == "disk4")
        #expect(DeviceInspector.normaliseWholeDisk("/dev/disk12s3") == "disk12")
        #expect(DeviceInspector.normaliseWholeDisk("/dev/rdisk7s2") == "disk7")
        #expect(DeviceInspector.normaliseWholeDisk("disk10") == "disk10")
    }

    @Test("Bus-Zuordnung folgt diskutil")
    func busMapping() {
        #expect(DeviceInspector.mapBus(protocolName: "USB", isInternal: false, isVirtual: false) == .usb)
        #expect(DeviceInspector.mapBus(protocolName: "USB", isInternal: true, isVirtual: false) == .internalDrive)
        #expect(DeviceInspector.mapBus(protocolName: "Apple Fabric", isInternal: true, isVirtual: false) == .internalDrive)
        #expect(DeviceInspector.mapBus(protocolName: "Disk Image", isInternal: false, isVirtual: false) == .virtual)
        #expect(DeviceInspector.mapBus(protocolName: "Secure Digital", isInternal: false, isVirtual: false) == .sdCard)
        #expect(DeviceInspector.mapBus(protocolName: "Thunderbolt", isInternal: false, isVirtual: false) == .thunderbolt)
        #expect(DeviceInspector.mapBus(protocolName: nil, isInternal: false, isVirtual: true) == .virtual)
        #expect(DeviceInspector.mapBus(protocolName: "Nonsense", isInternal: false, isVirtual: false) == .unknown)
    }
}
