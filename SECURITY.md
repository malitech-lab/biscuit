# Sicherheitsmodell

Biscuit erlangt Root-Rechte und schreibt direkt auf Blockgeräte. Dieses
Dokument beschreibt, was dabei abgesichert ist, was nicht, und warum.

## Warum überhaupt Root

Das Schreiben auf `/dev/rdiskN`, das Anlegen von Partitionstabellen und
`createinstallmedia` sind ohne Root-Rechte nicht möglich. Es gibt dafür keine
privilegienfreie API.

## Das Privilegien-Modell

Entgegen dem heute üblichen Muster installiert Biscuit **keinen dauerhaften
Root-LaunchDaemon**.

```
App-Start
  │
  ├─ erste privilegierte Aktion
  │    │
  │    ├─ 0700-Sitzungsverzeichnis unter ~/Library/Application Support/Biscuit/run/
  │    ├─ 32 Byte aus SecRandomCopyBytes in eine 0600-Datei
  │    ├─ native Admin-Abfrage (Touch ID / Passwort)
  │    └─ Helfer startet als root, bindet einen UNIX-Socket
  │
  ├─ Handshake: Token + Protokollversion
  ├─ Vorgang läuft
  │
  └─ App beendet → Verbindung fällt → Helfer beendet sich
```

Der Helfer beendet sich zusätzlich nach 300 Sekunden ohne Aktivität und nach 30
Sekunden, wenn sich überhaupt kein Client verbindet. Nach dem Beenden der App
bleibt kein privilegierter Prozess und keine Datei im System zurück.

### Warum nicht `SMAppService`

Ein dauerhafter Helfer per `SMAppService` müsste seine Clients über eine
Code-Signing-Anforderung autorisieren. Die setzt eine stabile Team-ID voraus,
also eine kostenpflichtige Apple-Developer-Mitgliedschaft. Das
sitzungsgebundene Modell erreicht denselben Zweck ohne Zertifikat — und hat eine
kleinere Angriffsfläche, weil es keinen Root-Prozess gibt, der auf eine
Verbindung wartet, während niemand hinsieht.

Es entspricht genau dem, was Rufus unter Windows tut: einmal pro Start
elevieren, nichts installieren.

## Was der Helfer prüft

Jede Verbindung muss alle folgenden Prüfungen passieren:

| Prüfung | Durchgesetzt durch |
|---|---|
| Socket nur für den Besitzer erreichbar | 0700-Verzeichnis, 0600-Socket, `chown` auf die UID |
| Anrufer ist derselbe Benutzer | `getpeereid()` — vom Kernel, nicht vom Peer behauptet |
| Anrufer läuft im erwarteten App-Bundle | `LOCAL_PEERPID` + `proc_pidpath()` |
| Anrufer kennt das Sitzungs-Token | konstantzeitiger Digest-Vergleich |
| Protokollversion passt | expliziter Vergleich, sonst Abbruch |
| Genau eine Verbindung | Listener wird nach `accept` sofort geschlossen und entfernt |
| Sitzungsverzeichnis ist kein Symlink | `lstat` + Prüfung auf Modus 0700 und Eigentümer |
| Token-Datei ist regulär und 0600 | `lstat` vor dem Lesen |

Zusätzlich beim Start:

- läuft nur mit `euid == 0`,
- lehnt `--uid 0` ab,
- liest alle Parameter aus `argv`, niemals aus der Umgebung.

## Was der Helfer dem Client *nicht* glaubt

Das Token beweist, dass die App die Elevation veranlasst hat. Es beweisterade
nicht, dass jede Anfrage legitim ist. Deshalb prüft der Helfer unabhängig nach:

**Geräte-Kennung.** Vor allem anderen wird die Form geprüft: `r?diskN(sN)*`,
nichts anderes. `diskutil info` nimmt nämlich auch Einhängepunkte an — `/`
eingeschlossen —, und eine durchgereichte Kennung würde die folgende
Systemdatenträger-Prüfung aushebeln, weil diese gegen normalisierte Namen wie
`disk3` vergleicht. Zusätzlich wird der Gerätename aus dem von `diskutil`
gemeldeten `DeviceIdentifier` abgeleitet, nicht aus der Anfrage; weichen beide
voneinander ab, bricht der Vorgang ab.

**Ziel-Datenträger.** Unmittelbar vor jedem destruktiven Schritt wird das Gerät
neu eingelesen und gegen die Anfrage geprüft: Es darf kein Systemdatenträger
sein, muss wechselbar und beschreibbar sein, und seine Größe darf um maximal
1 MiB von der erwarteten abweichen. BSD-Namen werden wiederverwendet — `disk4`
kann bei der Auswahl ein 32-GB-Stick und beim Bestätigen ein externes 4-TB-Archiv
sein. Ohne diese Prüfung wäre das eine ausnutzbare TOCTOU-Lücke.

**Quellpfade.** Pfade werden gegen eine Allow-List geprüft
(`/Volumes/`, `/Applications/`, `/private/var/tmp/biscuit-`) und auf
Traversal untersucht. Die App kann den Root-Prozess nicht auf `/etc/shadow`
zeigen lassen.

**Datenträgernamen.** Werden serverseitig normalisiert, nicht aus der App
übernommen.

**Programmpfade.** `wimToolPath` in der Anfrage ist ein *Vorschlag*, keine
Anweisung. Der Pfad wird zum Executable eines Root-Kindprozesses, also wird er
geprüft: nur der Basename `wimlib-imagex`, nur Verzeichnisse von der Allow-List
(das Verzeichnis des Helfers selbst, `/opt/homebrew/bin/`, `/usr/local/bin/`,
`/opt/local/bin/`), kein Traversal, und weder Datei noch Verzeichnis dürfen für
Gruppe oder andere schreibbar sein — ein schreibbares Verzeichnis erlaubt sonst
den Austausch nach der Prüfung. Das mitgelieferte wimlib findet der Helfer über
seinen **eigenen** Pfad, nicht über die Anfrage. Ein abgelehnter Vorschlag wird
übersprungen, nicht zum Abbruch: sonst wäre die Härtung eine
Denial-of-Service-Möglichkeit.

**Kindprozesse.** Werden mit festem, minimalem `PATH` und ohne `DYLD_*` gestartet
und immer über ein Argument-Vektor, niemals über eine Shell.

## Datenschutz: TCC und Dateideskriptoren

macOS schützt `~/Downloads`, `~/Dokumente`, `~/Desktop`, iCloud Drive und
Netzlaufwerke. **Root ist davon nicht ausgenommen**, und welcher Prozess bei
einem per Autorisierungsdialog gestarteten Daemon als „verantwortlich" gilt, hat
sich zwischen macOS-Versionen geändert.

Eine Implementierung, die dem Root-Prozess `/Users/x/Downloads/win11.iso`
übergibt, funktioniert daher auf einer macOS-Version und liefert auf der nächsten
`EPERM`. Biscuit öffnet Quelldateien deshalb **nie im Helfer**:

| Strategie | Was der Helfer bekommt |
|---|---|
| Abbild direkt schreiben | offener Dateideskriptor über `SCM_RIGHTS` |
| Windows-ISO | Mount-Punkt unter `/Volumes`, von der App read-only eingehängt |
| macOS-Installer | Pfad in `/Applications` (außerhalb des TCC-Geltungsbereichs) |

Die unprivilegierte App besitzt die Zustimmung des Benutzers, nicht der Helfer.
Nebeneffekt: Ein Deskriptor verweist auf die Inode, nicht auf den Namen — die
Quelle kann zwischen Prüfung und Schreiben nicht ausgetauscht werden.

## Die Vertrauenskette beim Download

Der Katalog entscheidet, welche URL geladen und an welcher Prüfsumme das
Ergebnis gemessen wird. Er ist damit **genauso sicherheitskritisch wie ein
App-Update** und wird identisch geschützt: Ed25519-Signatur mit dem
Release-Schlüssel des Projekts, dessen öffentlicher Teil im Build steckt.

```
GPG-Signatur des Herausgebers
   ↓  CI prüft gegen eingepinnten Fingerprint
Katalog, Ed25519-signiert
   ↓  App prüft die Signatur — bei jedem Laden, auch aus dem Cache
SHA-256 des Downloads
   ↓  Abweichung → Datei wird gelöscht, nicht mit Warnung angeboten
SHA-256 des entpackten Abbilds
   ↓  beim Schreiben verifiziert
```

### Warum die GPG-Prüfung in der CI liegt

macOS liefert kein GnuPG, und die unterstützten Distributionen nutzen vier
verschiedene Signatur-Layouts: abgetrennt binär, abgetrennt als `.sign`,
clearsigned inline, und Arch signiert das ISO selbst statt der Prüfsummendatei.
OpenPGP in der App nachzubauen wäre viel sicherheitskritischer Code für ein
Problem, das sich auf eine Maschine verschieben lässt, auf der `gpg` ohnehin
existiert.

Die App hat dadurch **genau einen** Prüfpfad, und jedes Glied der Kette wird von
etwas geprüft, das es auch prüfen kann.

Zwei Details, die leicht übersehen werden:

- `gpg --verify` liefert Exit 0 auch für eine gültige Signatur eines *beliebigen*
  bekannten Schlüssels. Der Generator vergleicht deshalb den Fingerprint aus
  `VALIDSIG` explizit gegen den Pin.
- Eine Quelle, deren Signatur nicht verifiziert werden kann, wird
  **weggelassen**, nicht mit Hinweis aufgenommen. Ein Katalogeintrag ist die
  Aussage, dass ein Download sicher auf eine fremde Platte geschrieben werden
  kann.

### Das zurückgehaltene erste Megabyte

Stimmt die Prüfsumme des entpackten Abbilds nicht, bleibt das erste Megabyte
ungeschrieben. Der Datenträger hat dann keine Partitionstabelle und ist
unmissverständlich unbrauchbar.

Das ist wichtiger, als es klingt: Ein Stick, der aus einem beschädigten Abbild
vollständig beschrieben wurde, **sieht fertig aus**. Er versagt später, auf
anderer Hardware, auf eine Weise, die niemand hierher zurückführt. Die Idee
stammt aus dem Schema von Raspberry Pi Imager.

### Der Zwischenspeicher wird nicht vertraut

Der Katalog-Cache liegt in Application Support, wo jeder Prozess dieses Benutzers
hineinschreiben kann. Er wird deshalb bei **jedem** Lesen neu signaturgeprüft und
bei Fehlschlag verworfen statt repariert. Heruntergeladene Abbilder werden vor
der Wiederverwendung erneut gehasht, nicht am Dateinamen wiedererkannt.

## Updates ohne Notarisierung

Die App ist nur ad-hoc signiert. Gatekeeper bürgt also für nichts. Vertrauen
entsteht stattdessen hier:

- Jedes Release-Archiv trägt eine abgetrennte **Ed25519-Signatur**.
- Der öffentliche Schlüssel ist in jeden Build einkompiliert.
- Der Updater verwirft jedes Archiv ohne gültige Signatur — unabhängig davon,
  woher es kam.
- Zusätzlich wird geprüft: Bundle-Version == Release-Version, Version ist
  tatsächlich neuer (kein Rollback auf ein neu getaggtes altes Release),
  App- und Helfer-Binary sind vorhanden und ausführbar.
- Der Austausch läuft über ein abgetrenntes Skript mit Rollback, falls das
  Verschieben fehlschlägt.

Ein Angreifer, der das Netz, den GitHub-Account oder die Release-Assets
kontrolliert, kann damit kein Update erzwingen. Der private Schlüssel ist der
einzige kritische Wert.

Updates werden mit `URLSession` geladen. Das Quarantäne-Attribut setzen nur
*herunterladende Anwendungen* — ein so geladenes Archiv trägt es gar nicht erst.
Das ist der dokumentierte Mechanismus, kein Umgehen von Gatekeeper.

## Bekannte Grenzen

Diese Punkte sind bewusst nicht abgesichert, weil sie außerhalb dessen liegen,
was ein Programm im Benutzerkontext leisten kann:

1. **Ein Angreifer mit dieser Benutzer-UID kann das Token lesen** und sich mit
   dem Helfer verbinden, solange eine Sitzung läuft. Derselbe Angreifer könnte
   aber auch selbst einen Admin-Dialog zeigen oder das App-Binary austauschen.
   Die eigentliche Grenze ist die interaktiv erteilte Administrator-Freigabe.

2. **Ein Angreifer mit Schreibrecht auf das App-Bundle** kann den Helfer
   ersetzen, der anschließend als Root startet. Dafür braucht es bereits
   Admin-Rechte. `Scripts/install.sh` setzt das Bundle auf `root:wheel` und
   entfernt Schreibrechte für Gruppe und andere; die App verweigert den Start
   eines gruppen- oder weltschreibbaren Helfers.

3. **Keine Notarisierung.** Auf fremden Macs greift Gatekeeper, wenn die App per
   Browser heruntergeladen wurde. Homebrew mit `--no-quarantine` oder ein Build
   aus dem Quellcode vermeiden das.

4. **Abbruch mitten im Schreiben hinterlässt ein unbrauchbares Medium.** Das ist
   unvermeidbar und wird klar kommuniziert, statt es zu verschleiern.

5. **Gefälschte Flash-Speicher** werden erst durch die Verifikation erkannt, die
   die Dauer verdoppelt. Sie ist standardmäßig aktiv.

6. **Die Prüfsumme eines Herausgebers ist nur so gut wie dessen Schlüssel.** Die
   Kette endet bei den Fingerprints in `Scripts/keys/`. Wer diese Datei im
   Repository ändern kann, kann die Kette brechen — genau wie beim privaten
   Release-Schlüssel.

7. **Ein selbst ersetztes Homebrew-wimlib wirkt auf den Root-Prozess.** Auf
   Apple Silicon gehört `/opt/homebrew` dem installierenden Benutzer. Wer seine
   eigene `/opt/homebrew/bin/wimlib-imagex` austauscht, beeinflusst damit, was
   als Root läuft. Das ist deutlich schwächer als die Ausführung eines
   beliebigen Pfades — es setzt die vorherige Änderung einer bekannten Stelle
   voraus, und es ist dasselbe Programm, das der Benutzer selbst installiert
   hat —, aber es bleibt eine Grenze. Wer sie nicht will, nutzt einen Build mit
   eingebundenem wimlib (`make app-wimlib`); dann liegt das Programm im
   Bundle, das `Scripts/install.sh` auf `root:wheel` setzt.

8. **libarchive meldet beschädigte gzip-Ströme nicht.** Gemessen auf macOS 27
   mit libarchive 3.7.4: Ein verfälschtes Byte wird für xz, bzip2 und zstd
   erkannt, für gzip nicht. Biscuit prüft die CRC-32 aus dem gzip-Trailer
   deshalb selbst. Sollte eine künftige libarchive-Version das ändern, bleibt
   die eigene Prüfung trotzdem korrekt.

## Schwachstellen melden

Sicherheitsrelevante Funde bitte **nicht** als öffentliches Issue. Nutze
GitHub Security Advisories (Tab „Security" → „Report a vulnerability").

Bitte angeben: macOS-Version, Biscuit-Version, Reproduktionsschritte und die
erwartete Auswirkung.
