<div align="center">

<img src="Resources/AppIcon-source.png" width="128" alt="">

# Biscuit

**B**oot **I**mage **S**tick **C**reation — **U**nified **I**nstaller **T**ool

Startfähige USB-Medien auf dem Mac. Abbild herunterladen und schreiben, in einem
Programm. Native macOS-App, keine Electron-Oberfläche, keine
Paketabhängigkeiten, kein dauerhafter Root-Dienst.

</div>

---

## Was es kann

| Aufgabe | Verfahren |
|---|---|
| **Windows 10/11-Stick** | GPT + FAT32, Dateikopie, `install.wim` wird in `.swm`-Teile unter 4 GB zerlegt |
| **Linux- und BSD-ISOs** | Byte für Byte auf `/dev/rdiskN`, mit Verifikation |
| **Komprimierte Abbilder** | `.gz`, `.xz`, `.bz2`, `.zip` werden beim Schreiben entpackt |
| **macOS-Installationsmedium** | Hülle um Apples `createinstallmedia` |
| **Abbild herunterladen** | signierter Katalog, fortsetzbar, Prüfsumme während des Ladens |
| **macOS herunterladen** | Liste und Download über Apples `softwareupdate` |
| **Windows beziehen** | Wegweiser zu Microsofts offizieller Seite, kein Eigendownload |
| **Windows-ISO prüfen** | Editionen, Sprachen, Build und Architektur aus `install.wim` |
| **Antwortdatei** | eigene prüfen **oder** erzeugen (TPM-Umgehung, lokales Konto, …) |
| **`autounattend.xml`** | Windows-Setup vorkonfigurieren, per Drag-and-Drop |
| **Stick zurücksetzen** | FAT32, exFAT, HFS+ oder APFS; GPT oder MBR |

Zweisprachig: Deutsch und Englisch, umschaltbar in den Einstellungen.

## Was es nicht tut

Das ist genauso wichtig:

- **Es bietet keine Methode an, die nicht starten kann.** Ein Windows-ISO roh zu
  schreiben ergibt einen Stick, den keine UEFI-Firmware bootet. Biscuit lässt
  diese Kombination gar nicht erst zu, statt sie anzubieten und später zu
  scheitern.
- **Es rät nicht bei Größen.** Ein gzip-Abbild speichert seine entpackte Größe
  modulo 4 GB — ein 9-GiB-Raspberry-Pi-Image meldet rund 737 MiB. Biscuit
  unterscheidet *exakt*, *ungefähr* und *unbekannt* und sagt, was davon zutrifft.
- **Es behauptet nicht, alles sei gleich gut geprüft.** Jeder Katalogeintrag
  zeigt, ob eine GPG-Signatur des Herausgebers verifiziert wurde oder nur eine
  Prüfsumme über TLS gelesen.
- **Es installiert keinen Hintergrunddienst.** Administrator-Rechte werden einmal
  pro Sitzung abgefragt und nur gehalten, solange ein Vorgang läuft.

## Voraussetzungen

- macOS 14 (Sonoma) oder neuer, Apple Silicon oder Intel
- Command Line Tools: `xcode-select --install` — nur zum Bauen
- `wimlib` nur für Windows-ISOs mit `install.wim` über 4 GB: `brew install wimlib`

Xcode ist **nicht** nötig. Ein Apple-Developer-Account ebenfalls nicht.

## Installation

### Homebrew

```sh
brew install --no-quarantine --cask malitech-lab/tap/biscuit-usb
```

Der Token heißt `biscuit-usb`, nicht `biscuit`: In Homebrews Haupt-Tap gibt es
bereits einen Cask namens `biscuit` für ein unverwandtes Programm. Taps sind
namensraum-getrennt, `biscuit` würde hier also auch funktionieren — aber wer
`brew install --cask biscuit` tippt, bekäme die andere Software.

### Aus dem Quellcode

```sh
git clone https://github.com/malitech-lab/biscuit.git
cd biscuit && Scripts/install.sh
```

### Release-ZIP

Herunterladen, nach `/Programme` ziehen, dann einmalig:

```sh
xattr -dr com.apple.quarantine /Applications/Biscuit.app
```

<details>
<summary><strong>Warum dieser Schritt nötig ist</strong></summary>

Biscuit ist nicht von Apple notarisiert. Notarisierung setzt eine
Developer-Mitgliedschaft für 99 €/Jahr voraus, die dieses Projekt bewusst nicht
hat.

Gatekeeper blockiert nicht „unsignierte Apps" an sich, sondern Dateien mit dem
Attribut `com.apple.quarantine`. Das setzen **herunterladende Programme**, also
Browser. Daraus folgt:

- Homebrew mit `--no-quarantine` setzt es nicht → keine Warnung.
- Ein lokal kompiliertes Bundle hat es nie → keine Warnung.
- Der eingebaute Updater lädt mit `URLSession` → keine Warnung.
- Nur der Browser-Download braucht den Befehl oben.

Dass die App nicht von Apple beglaubigt ist, bedeutet, dass du dem Projekt selbst
vertrauen musst. Prüfbar über die SHA-256 in den Release-Notizen und die
Ed25519-Signatur des Archivs.

</details>

## Bedienung

1. **Quelle** — Abbild hereinziehen oder aus dem Katalog laden. Biscuit hängt es
   ein, bestimmt den Typ und zeigt, was es gefunden hat.
2. **Antwortdatei** *(nur bei Windows-ISOs)* — optional eine `autounattend.xml`
   ablegen.
3. **Ziel** — Stick auswählen. Größe, Anschluss und vorhandene Volumes stehen dabei.
4. **Methode** — Vorauswahl passt meist.
5. **Schreiben** — ein Dialog nennt noch einmal genau das Gerät, das gelöscht
   wird. Einmal pro Sitzung folgt die Administrator-Abfrage.

## Sicherheit

Ausführlich in [SECURITY.md](SECURITY.md). Die beiden Kernpunkte:

**Privilegien.** Kein dauerhafter Root-Dienst. Der Helfer läuft sitzungsgebunden,
authentifiziert über ein 32-Byte-Token in einem 0700-Verzeichnis plus
`getpeereid()`, und beendet sich nach fünf Minuten Untätigkeit. Dasselbe Modell
wie Rufus unter Windows.

**Datenschutz.** macOS schützt `~/Downloads`, `~/Dokumente` und `~/Schreibtisch`
— und **Root ist davon nicht ausgenommen**. Der privilegierte Helfer öffnet
Quelldateien deshalb nie selbst: Die App reicht einen offenen Dateideskriptor
über `SCM_RIGHTS` weiter.

### Die Vertrauenskette beim Download

```
GPG-Signatur des Herausgebers
   ↓  CI prüft gegen eingepinnten Fingerprint
Katalog, mit Ed25519 signiert
   ↓  App prüft die Signatur
SHA-256 des Downloads
   ↓  bei Abweichung wird die Datei gelöscht
SHA-256 des entpackten Abbilds
   ↓  beim Schreiben verifiziert
```

Die GPG-Prüfung liegt in der CI, nicht in der App. macOS liefert kein GnuPG, und
die unterstützten Distributionen nutzen **vier verschiedene Signatur-Layouts**.
OpenPGP in der App nachzubauen wäre viel sicherheitskritischer Code für ein
Problem, das sich auf eine Maschine verschieben lässt, auf der `gpg` ohnehin
existiert. Die App hat dadurch genau einen Prüfpfad.

**Bei falscher Prüfsumme bleibt das erste Megabyte ungeschrieben.** Der
Datenträger hat dann keine Partitionstabelle — unmissverständlich unbrauchbar
statt scheinbar fertig. Ein Stick, der aus einem beschädigten Abbild beschrieben
wurde, versagt sonst später auf anderer Hardware, und niemand führt das hierher
zurück. Die Idee stammt aus dem Schema von Raspberry Pi Imager.

**macOS-Installationsprogramme gehen einen anderen Weg.** Sie werden über Apples
`softwareupdate --fetch-full-installer` geladen, nicht über diese Kette. Biscuit
pinnt dort keine Prüfsumme, und das ist kein Versäumnis: Apple veröffentlicht
keine stabilen Installer-URLs, `softwareupdate` prüft seinen Download selbst, und
es gibt keinen Spiegelserver, dem zu misstrauen wäre. Eine selbst gepflegte
Prüfsumme wäre hier schwächer als das Original, nicht stärker — sie würde nur
veralten. Die Oberfläche benennt den Unterschied, statt beide Quellen gleich
aussehen zu lassen.

<details>
<summary><strong>Warum das WIM selbst geparst wird, statt wimlib zu fragen</strong></summary>

Die Metadaten eines `install.wim` liegen in einem unkomprimierten XML-Block,
dessen Offset im 208-Byte-Header steht. Das sind rund achtzig Zeilen gegen einen
Prozessstart — und vor allem: wimlib ist hier eine *optionale* Abhängigkeit, nur
zum Teilen übergroßer Abbilder nötig. Die Prüfung davon abhängig zu machen hieße,
auf einem Rechner ohne Homebrew überhaupt nichts über ein ISO sagen zu können.

Das Format ist gegen eine echte, von wimlib 1.14.5 erzeugte Datei verifiziert,
und ein Test gleicht die gelesene Abbildanzahl mit `wiminfo` ab, wo vorhanden.

Nachgemessen wurde auch, dass der XML-Block in **allen** Kompressionsvarianten
unkomprimiert bleibt — ohne, LZX, XPRESS und solid/LZMS —, weshalb dieselbe
Leseroutine auch für `install.esd` trägt.

Daraus fällt zusätzlich die Antwort auf eine Frage, die sich sonst erst beim
Schreiben stellt: ob ein übergroßes Abbild geteilt oder konvertiert werden muss.
Die Dateiendung taugt dafür nicht, und die Kompressionsart im Header auch nicht —
ein solides und ein nicht-solides LZMS-Abbild tragen identische Header-Flaggen,
und nur eines lässt sich teilen. Entscheidend ist Bit `0x10` auf den Deskriptoren
der Blob-Tabelle.

Zwei Dinge sind dabei bewusst streng: das Größenfeld ist 56 Bit breit, kommt aus
einer heruntergeladenen Datei und wird daher gegen eine Obergrenze von 16 MiB und
gegen die echte Dateilänge geprüft — ungeprüft wäre das eine von fremden Bytes
gesteuerte Allokation von bis zu 64 PiB. Und geparst wird mit einem echten
XML-Parser, nicht mit regulären Ausdrücken: `<TOTALBYTES>` steht sowohl in
`<IMAGE>` als auch auf oberster Ebene und bedeutet dort Verschiedenes.

</details>

<details>
<summary><strong>Warum Biscuit Windows-ISOs nicht selbst herunterlädt</strong></summary>

Microsoft liefert diese ISOs unter keiner festen Adresse aus. Die Downloadseite
treibt eine dreistufige Sitzungs-API, deren letzte Stufe hinter
Geräte-Fingerprinting liegt. Für dieses Projekt nachgemessen: Stufe 1 und 2
antworten einem gewöhnlichen HTTP-Client normal — Stufe 2 liefert ordentlich 38
Sprachvarianten zu Build 26300.9457 —, Stufe 3 antwortet mit
`ErrorSettings.SentinelReject`.

Die statischen CDN-Links auf `software-static.download.prss.microsoft.com`
existieren und laufen nicht ab. Sie sind aber nur **hinter** dieser Sperre zu
bekommen, also lässt sich kein Katalog daraus bauen und erst recht keiner
aktuell halten. Die Sperre in die CI zu verschieben hilft nicht: abgelehnt wird
der Client, nicht die App.

Werkzeuge, die es dennoch automatisieren, stehen in einem Dauerwettlauf mit
Microsofts Abwehr und haben ihn mehrfach verloren. In Biscuit eingebaut hieße
das: der Download-Knopf geht an einem Tag kaputt, den Microsoft bestimmt, in
einer längst ausgelieferten Version.

Deshalb der Wegweiser. Der Browser passiert die Sperre, weil er einer ist;
Biscuit übernimmt danach den Teil, den es gut kann — prüfen, was angekommen ist.

</details>

## Technische Einordnung

<details>
<summary><strong>Warum Windows-ISOs nicht roh geschrieben werden</strong></summary>

Microsofts ISOs enthalten keinen hybriden MBR und keinen Isolinux-Bootsektor.
Byte für Byte kopiert findet die Firmware in der ersten Partition kein
FAT-Dateisystem und überspringt das Gerät. Nötig ist ein echtes FAT32-Volume mit
dem entpackten ISO-Inhalt.

</details>

<details>
<summary><strong>Warum FAT32 und nicht NTFS oder exFAT</strong></summary>

UEFI-Firmware muss laut Spezifikation nur FAT unterstützen. exFAT kann sie nicht
lesen, und macOS kann NTFS nicht schreiben. Rufus löst den Fall „Datei über 4 GB"
mit einer NTFS-Partition plus eigenem UEFI:NTFS-Treiber-Shim — auf macOS nicht
reproduzierbar. Deshalb wird `install.wim` in `install.swm`-Teile zerlegt;
Windows Setup liest die nativ.

Die naheliegende Alternative — kleine FAT32-Bootpartition plus exFAT-Datenpartition —
ist **nicht** implementiert, weil die Firmware exFAT nicht lesen kann. Ein Stick,
der scheinbar fertig ist und dann nicht bootet, ist schlechter als eine klare
Fehlermeldung.

</details>

<details>
<summary><strong>Warum Windows-ISOs nicht wie bei Rufus geladen werden</strong></summary>

Rufus' Download-Kette funktioniert — sie wurde für dieses Projekt live
nachgestellt. Aber sie ist in vier Jahren **sechsmal** gebrochen, einmal für fünf
Tage, und Microsoft arbeitet nachweislich gezielt dagegen. Die Session ist
einmalig verwendbar, VPN- und Rechenzentrums-IPs werden geblockt.

Biscuit nutzt stattdessen die statischen Links auf
`software-static.download.prss.microsoft.com`: kein Token, kein Ablauf,
fortsetzbar, Sprache und Architektur im Pfad substituierbar. Zu pflegen ist ein
Manifest-Eintrag pro Windows-Release statt Reverse Engineering unter Zeitdruck.

</details>

<details>
<summary><strong>Warum <code>.zst</code> abgelehnt wird</strong></summary>

Das libarchive, das macOS mitliefert, ist ohne zstd gebaut und startet dafür ein
externes Programm `zstd -d -qq`. Der bereinigte `PATH` des privilegierten Helfers
enthält es nicht, und einen Homebrew-Pfad in einen Root-Prozess zu injizieren wäre
genau die PATH-Schwäche, die dieses Projekt sonst vermeidet. Ein angekündigtes
Format, das beim Schreiben scheitert, ist schlechter als eine ehrliche Absage.

`.gz`, `.xz`, `.bz2` und `.zip` sind einkompiliert und funktionieren.

</details>

## Aufbau

```
Sources/
  BiscuitKit/        Modelle, IPC, ISO-Analyse, Kompression, Katalog, Schreiben
  BiscuitHelper/     privilegierter Prozess: Socket-Server + Disk-Operationen
  BiscuitApp/        SwiftUI-Oberfläche, Privilegien-Broker, Updater
  CBiscuitArchive/   Brücke zum System-libarchive
Scripts/
  bundle.sh              .app aus den SwiftPM-Produkten zusammensetzen
  install.sh             bauen und nach /Programme installieren
  build-catalogue.py     Katalog bauen, Publisher-Signaturen prüfen
  sign-catalogue.sh      Katalog mit Ed25519 signieren
  keygen.sh              Release-Schlüssel erzeugen
  package-release.sh     Archiv packen, signieren, verifizieren
  vendor-wimlib.sh       wimlib ins Bundle einbetten
  keys/                  eingepinnte Publisher-Schlüssel
```

### Bauen

```sh
make doctor     Umgebung prüfen
make build      beide Binaries
make test       Testsuite
make app        dist/Biscuit.app
make run        bauen und starten
make help       alle Ziele
```

> **Nutze `make`, nicht `swift build` direkt.** Ohne Xcode braucht SwiftUI ein
> SDK-Override, das das Makefile automatisch setzt.

<details>
<summary><strong>Warum das SDK-Override nötig ist</strong></summary>

In macOS-SDKs ab 15.4 sind SwiftUIs `@State` und `@Binding` keine Property
Wrapper mehr, sondern Makros, deren Plugin nur mit vollständigem Xcode kommt.
`Scripts/select-sdk.sh` wählt das neueste SDK, in dem sie noch Property Wrapper
sind. Das Deployment-Target bleibt bei macOS 14. Mit Xcode passiert nichts davon.

</details>

### Katalog bauen

```sh
Scripts/build-catalogue.py --dry-run --output /dev/null   # Quellen prüfen
Scripts/build-catalogue.py --output dist/catalogue.json   # mit GPG-Prüfung
Scripts/sign-catalogue.sh --catalogue dist/catalogue.json
```

Die CI tut das täglich — der Katalog ändert sich, wenn eine Distribution
veröffentlicht, nicht wenn Biscuit es tut.

### Ein Release vorbereiten

Einmalig, bevor das erste Release gebaut wird:

```sh
make keygen                                     # Ed25519-Schlüsselpaar nach secrets/
gh secret   set BISCUIT_RELEASE_PRIVATE_KEY < secrets/biscuit-release.key
gh variable set BISCUIT_UPDATE_PUBKEY --body "$(cat secrets/biscuit-release.pub)"
```

`secrets/` steht in `.gitignore`. Den privaten Schlüssel zusätzlich offline
sichern: ohne ihn lässt sich **kein** weiteres Update ausliefern, denn die
installierte App akzeptiert nur Archive, die zum eingebetteten öffentlichen
Schlüssel passen.

Dann pro Release:

```sh
BISCUIT_UPDATE_REPO=malitech-lab/biscuit \
BISCUIT_UPDATE_PUBKEY="$(cat secrets/biscuit-release.pub)" \
  make package
```

`BISCUIT_UPDATE_REPO` entscheidet, wo die ausgelieferte App nach Updates fragt.
Der Vorgabewert ist dieses Repository; `Scripts/package-release.sh` bricht ab,
wenn stattdessen noch ein Platzhalter im Bundle steht — eine Warnung wäre hier
zu wenig, weil die App Archive von dort akzeptiert, sofern deren Signatur zum
eingebetteten Schlüssel passt.

**Wer forkt, muss beides setzen.** Sonst fragt der Fork bei diesem Repository
nach Updates. Nötig sind ein eigenes Schlüsselpaar (`make keygen`) und ein
eigenes `BISCUIT_UPDATE_REPO`; beides lässt sich auch über die `Info.plist`
überschreiben, ohne den Code zu ändern.

Die Homebrew-Cask entsteht aus `Packaging/biscuit-usb.rb.in`: der
Release-Workflow setzt Version, SHA-256 und Repository ein und hängt das
Ergebnis an das GitHub-Release. Für den Tap wird die Datei als
`Casks/biscuit-usb.rb` in das Tap-Repository kopiert.

## Tests

333 Tests in 56 Suites, überwiegend Integrationstests statt Mocks:

| Bereich | Wie getestet |
|---|---|
| Schreiben | gegen ein per `hdiutil` angehängtes **echtes Blockgerät** |
| Verifikation | ein einzelnes verfälschtes Byte muss auffallen |
| Prüfsummen-Schutz | bei Abweichung muss der Bootsektor leer bleiben |
| Kompression | echte `gzip`/`xz`/`bz2`-Archive, Rundlauf und Beschädigung |
| Privilegiengrenze | echter Server auf echtem Socket, echter Client |
| Deskriptor-Übergabe | `SCM_RIGHTS` über die Privilegiengrenze |
| Katalog | Signatur, Manipulation, Fremdschlüssel, Schema-Drift |
| Release-Signatur | CryptoKit gegen die **tatsächliche** `openssl`-Signatur |
| Lokalisierung | jeder Schlüssel in beiden Sprachen, Platzhalter konsistent |

Zwei Entwurfsentscheidungen machen das möglich: angehängte Images statt Hardware,
und ein Server, der nichts über Datenträger weiß — alles, was Root braucht, liegt
hinter einem Protokoll.

**Nicht automatisiert getestet:** `diskutil`-Partitionierung und
`createinstallmedia` (brauchen Root), die Privilegien-Eskalation selbst, und ob
ein erzeugter Stick auf fremder Firmware bootet. Vor dem ersten ernsten Einsatz
also einmal mit einem Datenträger testen, dessen Inhalt entbehrlich ist.

## Grenzen

- **Kein Legacy-BIOS-Start für Windows.** Das FAT32-Layout startet per UEFI.
- **Keine Byte-Verifikation bei Dateikopien.** Bei Windows- und macOS-Medien wird
  stattdessen die Vollständigkeit der Boot-Dateien geprüft.
- **macOS-Installer müssen in `/Programme` liegen.** Aus `~/Downloads` darf der
  privilegierte Helfer aus Datenschutzgründen nicht lesen.
- **Abbruch mitten im Schreiben hinterlässt ein unbrauchbares Medium.**

## Lizenz

GPL-3.0-or-later. Siehe [LICENSE](LICENSE) und [THIRD-PARTY.md](THIRD-PARTY.md) —
die GPL ist eine Folge der eingebetteten wimlib.
