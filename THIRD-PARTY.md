# Fremdkomponenten

## wimlib — mitgeliefert

Biscuit ruft `wimlib-imagex` auf, um `install.wim` in `install.swm`-Teile unter
der 4-GB-Grenze von FAT32 zu zerlegen. Ohne das lässt sich aus einem aktuellen
Windows-ISO kein FAT32-Medium erstellen, und FAT32 ist das einzige Dateisystem,
das UEFI-Firmware zuverlässig lesen kann.

- Projekt: https://wimlib.net
- Bibliothek `libwim`: LGPL-3.0-or-later
- Programm `wimlib-imagex`: GPL-3.0-or-later
- Autor: Eric Biggers

`Scripts/vendor-wimlib.sh` kopiert das Programm und seine Bibliotheken nach
`Biscuit.app/Contents/`. Release-Builds enthalten diese Kopie; lokale Builds
greifen auf die Homebrew-Installation zurück.

**Weil `wimlib-imagex` unter der GPL steht, steht Biscuit ebenfalls unter
GPL-3.0-or-later.** Das ist keine beiläufige Entscheidung, sondern die
Voraussetzung dafür, das Programm mitliefern zu dürfen.

Der korrespondierende Quellcode ist über die Projektseite verfügbar. Auf Anfrage
stellt dieses Repository den exakten Stand bereit, der in einem Release
eingebettet wurde — die Version steht in den Release-Notizen.

## libarchive — vom System

Entpackt komprimierte Abbilder im Strom, ohne Zwischendatei. macOS liefert es
mit; Biscuit bindet keine eigene Kopie ein.

```
libarchive 3.7.4  zlib/1.2.12  liblzma/5.4.3  bz2lib/1.0.8
```

Der Header `archive.h` ist nicht Teil des Command-Line-Tools-SDK, die Bibliothek
aber im dyld-Cache vorhanden. `Sources/CBiscuitArchive` deklariert die benötigten
Funktionen selbst. Das ist hier gefahrlos, weil **jeder libarchive-Typ ein opaker
Zeiger ist** — es gibt kein Speicherlayout, das zwischen Versionen abweichen
könnte. Mit `lzma_stream`, dessen Felder zum ABI gehören, wäre derselbe Griff
fahrlässig.

- Projekt: https://libarchive.org
- Lizenz: BSD-2-Clause
- Eingebaute Filter: gzip, xz, bzip2 — **nicht** zstd (siehe README)

## zlib — vom System

Liefert `crc32()` für die Integritätsprüfung von gzip-Strömen. Hardwarebeschleunigt,
was bei einem 9-GB-Abbild spürbar ist.

- Lizenz: zlib-Lizenz
- Header im SDK vorhanden, regulär verlinkt

## Signaturschlüssel der Distributionen

`Scripts/keys/` enthält die öffentlichen GPG-Schlüssel, gegen die der
Katalog-Generator die Prüfsummen der Herausgeber verifiziert:

| Datei | Fingerprint | Herausgeber |
|---|---|---|
| `debian.asc` | `DF9B9C49EAA9298432589D76DA87E80D6294BE9B` | Debian CD signing key |
| `ubuntu.asc` | `843938DF228D22F7B3742BC0D94AA3F0EFE21092` | Ubuntu CD Image Automatic Signing Key |
| `mint.asc` | `27DEB15644C6B3CF3BD7D291300F846BA25BAE09` | Linux Mint ISO Signing Key |
| `arch.asc` | `3E80CA1A8B89F69CBA57D98A76A5EF9054449A5C` | Arch Linux Release Engineering |

Fedora rotiert seinen Schlüssel pro Release; der Generator lädt stattdessen den
offiziellen Keyring von `fedoraproject.org/fedora.gpg`.

Die Schlüssel liegen im Repository, statt sie zur Bauzeit von einem Keyserver zu
holen. Das hat zwei Gründe: Keyserver sind unzuverlässig — zwei von vier Abrufen
scheiterten bei der Entwicklung — und eine Schlüsselrotation soll ein bewusster
Commit sein, kein stiller Wechsel auf das, was ein Keyserver gerade zurückgab.

Die Fingerprints stammen aus der Dokumentation der jeweiligen Distribution und
wurden gegen den Schlüssel geprüft, der die Prüfsummendatei tatsächlich signiert
hat. Ausnahme: Arch veröffentlicht nur die 32-Bit-Kurzkennung, die
kryptografisch wertlos ist; der vollständige Fingerprint wurde aus dem
Signaturpaket gelesen und gilt als beim ersten Kontakt festgelegt.

## Von Apple mitgelieferte Werkzeuge

Aufgerufen, aber nicht mitgeliefert — Teil von macOS:

| Werkzeug | Zweck |
|---|---|
| `/usr/sbin/diskutil` | Geräte auflisten, aushängen, partitionieren, formatieren |
| `/usr/bin/hdiutil` | ISO-Abbilder read-only einhängen |
| `/usr/bin/osascript` | nativer Administrator-Dialog für die Elevation |
| `/usr/bin/ditto` | Archive packen und entpacken, ohne Bundles zu beschädigen |
| `/usr/bin/iconutil` | App-Icon erzeugen (nur beim Bauen) |
| `/usr/bin/curl` | HTTP im Katalog-Generator |
| `createinstallmedia` | aus dem jeweiligen macOS-Installationsprogramm |

## Keine Paketabhängigkeiten

`Package.swift` hat keinen einzigen `dependencies`-Eintrag. Verwendet werden
ausschließlich SwiftUI, Observation, CryptoKit, DiskArbitration, Security und
Foundation aus dem System-SDK, plus die oben genannten Systembibliotheken.

Das ist Absicht. Eine Anwendung, die als Root auf Blockgeräte schreibt, sollte
keine Lieferkette haben, die man nicht vollständig überblicken kann.
Insbesondere gibt es kein Sparkle — die Update-Prüfung sind rund 200 Zeilen
gegen die GitHub-Releases-API, deren Vertrauensanker ein Ed25519-Schlüssel ist,
der zum Projekt gehört.

## Konzeptionelle Anleihen

Kein Code übernommen, aber die Ideen sind nicht meine:

- **Raspberry Pi Imager** (Apache-2.0) — das Katalogformat mit `extract_size`
  und `extract_sha256`, und der Kniff, bei Prüfsummenfehler das erste Megabyte
  nicht zu schreiben. Biscuit hostet einen eigenen Katalog im selben Schema;
  rpi-imager sieht Dritt-Kataloge über `--repo` ausdrücklich vor.
- **Rufus** — das Privilegienmodell „einmal pro Start elevieren, nichts
  installieren", und die Erkenntnis, dass Windows-ISOs eine Dateikopie brauchen.
- **balenaEtcher** — die Erwartung, dass ein Schreibwerkzeug nach dem Schreiben
  verifiziert und komprimierte Abbilder im Strom entpackt.

## Lizenz dieses Projekts

GPL-3.0-or-later. Vollständiger Text in [LICENSE](LICENSE).
