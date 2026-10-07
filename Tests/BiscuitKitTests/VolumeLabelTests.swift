import Testing
@testable import BiscuitKit

@Suite("Volume-Label-Normalisierung")
struct VolumeLabelTests {
    @Test("FAT32 kürzt auf 11 Zeichen und schreibt groß")
    func fat32() {
        #expect(VolumeLabel.sanitise("Windows 11 Setup", filesystem: .fat32) == "WINDOWS11SE")
        #expect(VolumeLabel.sanitise("ubuntu", filesystem: .fat32) == "UBUNTU")
        #expect(VolumeLabel.sanitise("a", filesystem: .fat32) == "A")
    }

    /// exFAT: 11 Zeichen, nicht 15.
    ///
    /// Dieser Test behauptete 15 — und bestand, weil er die Bereinigung gegen
    /// dieselbe falsche Konstante hielt, die er prüfen sollte. Eine
    /// geschlossene Schleife: beide Seiten stimmten überein, beide waren
    /// falsch. Aufgefallen ist es erst, als `diskutil` auf echter Hardware das
    /// gekürzte Etikett eines Windows-ISOs ablehnte — nach dem Überschreiben
    /// der Signaturen.
    ///
    /// Die Zahl wird jetzt zusätzlich in `VolumeLabelAgreementTests` gegen das
    /// echte Werkzeug gemessen. Dieser Test prüft die Bereinigung, jener den
    /// Grenzwert; nur zusammen taugen sie.
    @Test("exFAT kürzt auf 11 Zeichen und behält die Schreibweise")
    func exfat() {
        #expect(VolumeLabel.sanitise("MeinStick", filesystem: .exfat) == "MeinStick")
        #expect(
            VolumeLabel.sanitise("EinSehrLangerNameHier", filesystem: .exfat)
                == "EinSehrLang"
        )
        // Genau das Etikett, das auf dem Stick gescheitert ist.
        #expect(
            VolumeLabel.sanitise("CCCOMA_X64FRE_DE-DE_DV9", filesystem: .exfat)
                == "CCCOMA_X64F"
        )
    }

    @Test("Verbotene Zeichen werden entfernt, nicht ersetzt")
    func strippedCharacters() {
        // Importantly these are removed rather than mapped to underscores:
        // a label of "____" tells the user nothing about which stick it is.
        #expect(VolumeLabel.sanitise("my/stick:name", filesystem: .exfat) == "mystickname")
        #expect(VolumeLabel.sanitise("a b c", filesystem: .exfat) == "abc")
        #expect(VolumeLabel.sanitise("keep-me_too", filesystem: .exfat) == "keep-me_too")
    }

    @Test("Nicht-ASCII wird verworfen, damit Bytelänge = Zeichenlänge gilt")
    func nonASCII() {
        // Byte length must match character length, otherwise an 11-character
        // label can still overflow FAT32's 11-byte field.
        #expect(VolumeLabel.sanitise("Grüße", filesystem: .exfat) == "Gre")
        #expect(VolumeLabel.sanitise("日本語", filesystem: .exfat) == "BISCUIT")
        #expect(VolumeLabel.sanitise("café", filesystem: .fat32) == "CAF")
    }

    @Test("Leere Eingabe fällt auf einen gültigen Namen zurück")
    func emptyFallback() {
        #expect(VolumeLabel.sanitise("", filesystem: .exfat) == "BISCUIT")
        #expect(VolumeLabel.sanitise("   ", filesystem: .exfat) == "BISCUIT")
        #expect(VolumeLabel.sanitise("!!!", filesystem: .fat32) == "BISCUIT")
        // The fallback itself must respect the limit.
        #expect(VolumeLabel.sanitise("", filesystem: .fat32).count <= 11)
    }

    @Test("Ergebnis hält immer das Limit des Dateisystems ein")
    func alwaysWithinLimit() {
        let inputs = [
            "", "x", "einganzlangerstringohneende",
            "MIXED-case_123", "///", "ÄÖÜ", String(repeating: "z", count: 300)
        ]
        for filesystem in TargetFilesystem.allCases {
            for input in inputs {
                let result = VolumeLabel.sanitise(input, filesystem: filesystem)
                #expect(!result.isEmpty)
                #expect(result.count <= VolumeLabel.maximumLength(for: filesystem))
                #expect(result.utf8.count == result.count, "Bytelänge muss Zeichenlänge entsprechen")
            }
        }
    }
}
