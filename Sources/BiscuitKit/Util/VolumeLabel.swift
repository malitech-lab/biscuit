import Foundation

/// Normalises a user-entered volume name into something the target filesystem
/// will actually accept.
///
/// Single source of truth on purpose. The privileged helper must enforce this,
/// because it cannot trust the app; the app must predict it, because the user
/// needs to see the real result before committing. Two independent
/// implementations would drift, and the first symptom would be `diskutil`
/// failing after the stick had already been wiped.
public enum VolumeLabel {
    public static let fallback = "BISCUIT"

    public static func maximumLength(for filesystem: TargetFilesystem) -> Int {
        switch filesystem {
        // FAT32 stores an 11-byte 8.3-style label in the boot sector.
        case .fat32: return 11
        // exFAT: 11, nicht 15.
        //
        // Hier stand 15, und niemand hat es gemerkt, weil kein Test die Werte
        // je gegen `diskutil` gehalten hat. Aufgefallen beim ersten echten
        // Löschversuch: das Etikett eines Windows-ISOs („CCCOMA_X64FRE_D", auf
        // 15 gekürzt) wurde von `diskutil eraseDisk` mit
        // „does not appear to be a valid volume name for its file system“
        // abgelehnt — nachdem die Signaturen bereits überschrieben waren.
        //
        // Gemessen an einem Wegwerf-Abbild: 11 Zeichen werden angenommen, 12
        // abgelehnt. Die exFAT-Spezifikation sieht für den Eintrag
        // „Volume Label“ ebenfalls 11 Zeichen vor. `VolumeLabelAgreementTests`
        // hält das jetzt gegen das echte Werkzeug.
        case .exfat: return 11
        case .hfsPlus, .apfs: return 127
        }
    }

    public static func requiresUppercase(for filesystem: TargetFilesystem) -> Bool {
        filesystem == .fat32
    }

    /// Keeps ASCII alphanumerics plus `-` and `_`, folds case where the
    /// filesystem demands it, and truncates to the hard limit.
    ///
    /// The character set is deliberately narrower than each filesystem strictly
    /// permits: labels with spaces or non-ASCII characters are accepted by
    /// `diskutil` but then render inconsistently in Windows Setup, UEFI boot
    /// menus and `/Volumes`, which makes the stick hard to identify at exactly
    /// the moment it matters.
    public static func sanitise(_ raw: String, filesystem: TargetFilesystem) -> String {
        let limit = maximumLength(for: filesystem)

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_")
        // `CharacterSet.alphanumerics` includes non-ASCII letters; restrict to
        // ASCII so the byte length matches the character count.
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar.isASCII && allowed.contains(scalar) {
            scalars.append(scalar)
        }

        var label = String(scalars)
        if requiresUppercase(for: filesystem) {
            label = label.uppercased()
        }
        label = String(label.prefix(limit))

        return label.isEmpty ? String(fallback.prefix(limit)) : label
    }
}
