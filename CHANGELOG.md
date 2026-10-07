# Änderungsprotokoll

Format nach [Keep a Changelog](https://keepachangelog.com/de/1.1.0/),
Versionierung nach [Semantic Versioning](https://semver.org/lang/de/).

## [Unveröffentlicht]

Das Projekt hieß während der Entwicklung zunächst *BootForge*. Die Umbenennung
nach **Biscuit** erfolgte vor jeder Veröffentlichung; es gibt keine Installation
unter dem alten Namen, die migriert werden müsste.

### Hinzugefügt

**Medien erstellen**

- Windows-10/11-Medien: GPT + FAT32 mit automatischer Zerlegung von
  `install.wim` in `install.swm`-Teile unter der 4-GB-Grenze.
- **`install.esd` wird vollständig ausgelesen.** Die Annahme war, dass derselbe
  Leser trägt, weil der XML-Block unabhängig von der Kompression unkomprimiert
  gespeichert ist — nachgemessen über alle vier Varianten. Geprüft war das aber
  nie an einer Datei, die tatsächlich wie ein ESD aussieht *und* so heißt.
  Jetzt schon: Fixture aus `wimlib-imagex export --solid --compress=LZMS`, und
  ein Test bestätigt, dass `wimlib-imagex split` sie mit Exit 68 ablehnt.
- **Antwortdateien lassen sich erzeugen**, nicht nur prüfen: TPM-/Secure-Boot-,
  RAM-, CPU- und Speicherprüfung überspringen, Setup ohne Microsoft-Konto
  abschließen, Lizenz- und WLAN-Seiten überspringen, optionale Diagnosedaten
  ablehnen, lokales Konto anlegen. Die Prozessorarchitektur kommt aus dem
  geprüften Abbild, nicht aus einer Rückfrage — Windows Setup vergleicht
  `processorArchitecture` strikt und **ignoriert eine unpassende Datei
  stillschweigend**.

  Jede erzeugte Datei läuft durch dieselbe Prüfung, die auch mitgebrachte
  Dateien bewacht. Ein Test erzeugt alle 128 Optionskombinationen und verlangt,
  dass jede besteht; ein Fehler im Erzeuger fällt damit hier auf und nicht auf
  einem fertigen Stick.

  Benannt wird auch, was es kostet: die Hardware-Umgehung ergibt eine
  Installation, die Microsoft nicht unterstützt und von Updates ausschließen
  kann, und der Weg am Microsoft-Konto vorbei ist der von allen Optionen, der
  auf einem aktuellen Build am ehesten nicht mehr greift. Beides steht in der
  Oberfläche, nicht im Kleingedruckten.
- **Windows-ISOs werden ausgelesen**: Editionen, Sprachen, Build-Nummer und
  Architektur stehen nach der Prüfung in der Oberfläche. Gelesen direkt aus dem
  XML-Block im `install.wim` — **ohne wimlib**, das hier nur optional ist und zum
  Teilen übergroßer Abbilder dient. Ein ARM64-Abbild und ein einzelner Teil eines
  geteilten Satzes werden als Warnung herausgehoben, nicht als Fußnote: beides
  ergibt sonst ein Medium, das fehlerfrei fertig wird und nicht bootet.
- **Windows-Wegweiser**: Biscuit öffnet Microsofts offizielle Downloadseite im
  Browser — getrennt nach Windows 11 (x64), Windows 11 (ARM64) und Windows 10 —
  und sagt in der Oberfläche, *warum* es nicht selbst lädt.
- **macOS-Installationsprogramme** werden über Apples `softwareupdate`
  aufgelistet und geladen; das Ergebnis landet in `/Programme` und wird von
  `createinstallmedia` zum Medium verarbeitet. Hier pinnt Biscuit bewusst
  **keine** Prüfsumme: Apple liefert und prüft selbst, es gibt keinen
  Spiegelserver, dem zu misstrauen wäre. Die Oberfläche sagt das auch so.
- Rohschreiben hybrider ISOs und Datenträgerabbilder auf `/dev/rdiskN` mit
  optionaler Byte-für-Byte-Verifikation.
- **Komprimierte Abbilder** (`.gz`, `.xz`, `.bz2`, `.zip`) werden beim Schreiben
  im Strom entpackt — kein Zwischenspeichern, kein doppelter Platzbedarf. Über
  das libarchive, das macOS mitliefert; keine eingebettete Kopie.
- macOS-Installationsmedien über Apples `createinstallmedia`.
- Löschen und Formatieren: FAT32, exFAT, HFS+, APFS; GPT oder MBR.
- **`autounattend.xml`** per Drag-and-Drop für Windows-ISOs, mit Validierung von
  Wohlgeformtheit, Wurzelelement und Namensraum — und einer Warnung, wenn die
  Datei Anmeldedaten im Klartext enthält.

**Abbilder beziehen**

- Signierter Katalog mit Debian, Fedora, Ubuntu und Arch Linux. Der Generator
  verifiziert die GPG-Signaturen der Herausgeber gegen eingepinnte Fingerprints;
  eine Quelle, die sich nicht verifizieren lässt, wird weggelassen statt
  ungeprüft aufgenommen.
- Fortsetzbarer Download mit Prüfsummenbildung während des Ladens.
- Jeder Eintrag zeigt die Herkunft seiner Prüfsumme: geprüfte GPG-Signatur, nur
  TLS, oder gar nichts. Diese drei Fälle sehen in der Oberfläche verschieden aus.
- **Bei falscher Prüfsumme bleibt das erste Megabyte ungeschrieben.** Der
  Datenträger hat dann keine Partitionstabelle statt eines scheinbar fertigen
  Systems, das erst auf fremder Hardware versagt.

**Grundlagen**

- Sitzungsgebundener privilegierter Helfer: eine Administrator-Abfrage pro
  Sitzung, kein dauerhafter Root-Dienst, Beendigung nach fünf Minuten
  Untätigkeit.
- Zweisprachige Oberfläche, Deutsch und Englisch, umschaltbar zur Laufzeit.
  Diagnosetexte bleiben bewusst englisch und unlokalisiert, damit sie in
  Fehlerberichten vergleichbar bleiben.
- Selbstaktualisierung über GitHub Releases mit Ed25519-Signaturprüfung.
- Prüfung der Boot-Dateien nach dem Schreiben, statt ein Medium auszuliefern,
  das erst beim Start versagt.

### Entschieden gegen

- **Automatisierter Windows-ISO-Download, in jeder Form.** Die Fido-Kette ist in
  vier Jahren sechsmal gebrochen, einmal für fünf Tage. Der erste Plan war
  deshalb, die Sitzungs-API zu meiden und stattdessen statische Links auf
  `software-static.download.prss.microsoft.com` im Manifest zu pflegen.

  **Dieser Plan ist an einer Messung gescheitert und wurde verworfen.** Live
  nachgestellt: Schritt 1 (Sitzung registrieren) und Schritt 2
  (`getskuinformationbyproductedition`, 38 Sprachen, Build 26300.9457)
  antworten einem gewöhnlichen HTTP-Client normal. Schritt 3
  (`GetProductDownloadLinksBySku`) antwortet mit
  `ErrorSettings.SentinelReject` — Microsofts Geräte-Fingerprinting
  (ThreatMetrix, `org_id=y6jn8c31`) lehnt den Client ab. Die statischen Links
  *existieren* und laufen nicht ab, sind aber **nur hinter dieser Sperre zu
  bekommen**. Ein Manifest davon lässt sich also gar nicht erst aufbauen, und in
  die CI zu verschieben hilft nicht: abgelehnt wird der Client, nicht die App,
  und ein GitHub-Runner ist derselbe Fall.

  Stattdessen ein Wegweiser: Biscuit öffnet die offizielle Seite im Browser —
  der die Sperre passiert, weil er einer ist — und prüft danach, was
  zurückkommt. Das kostet einen Klick und kann nicht verrotten.
- **`.zst`-Unterstützung.** Das libarchive von macOS ist ohne zstd gebaut und
  startet ein externes Programm, das der bereinigte `PATH` des Helfers nicht
  enthält. Einen Homebrew-Pfad in einen Root-Prozess zu injizieren wäre genau die
  Schwäche, die das Projekt sonst vermeidet.
- **FAT32-Boot- plus exFAT-Datenpartition für Windows.** UEFI-Firmware kann exFAT
  nicht lesen. Das Ergebnis wäre ein Medium gewesen, das fertig aussieht und
  nicht bootet.
- **OpenPGP in der App.** Vier Signatur-Layouts und kein GnuPG auf macOS. Die
  Prüfung liegt in der CI, wo `gpg` existiert; die App hat einen Prüfpfad.
- **Mehrere Ziele gleichzeitig beschreiben.** Erheblicher Nebenläufigkeitsaufwand
  für einen seltenen Fall, der die Risikofläche einer destruktiven Operation
  vervielfacht. Zurückgestellt, bis jemand es konkret braucht.

### Werkzeuge

- `make lint` prüft jetzt mit `--severity=style` statt `warning` und schließt
  die Python-Skripte per Syntaxprüfung ein. Der Katalog-Generator läuft in der
  CI gegen echte Server; ein Syntaxfehler darin fiel bisher erst dort auf. Die
  einzige Ausnahme (SC2012 in `package-release.sh`) ist mit Begründung
  abgeschaltet — die Ausgabe wird dort angezeigt, nicht geparst. Die CI nutzt
  dieselbe Stufe, damit lokal und dort dasselbe gilt.

### Behoben — während der Entwicklung gefunden

Diese Fehler wurden durch Integrationstests gegen echte Geräte, echte Werkzeuge
und echte Server sichtbar. Jeder hätte in Produktion zu einem unbrauchbaren
Medium oder einem hängenden Vorgang geführt.

- **Ein gebrochenes Rohr konnte den ganzen Prozess beenden.** Der Helfer setzt
  `SIGPIPE` seit immer auf `SIG_IGN`, mit der richtigen Begründung: eine
  verschwundene Gegenseite darf keinen Prozess beenden, der mitten im
  Beschreiben eines Datenträgers steckt. Die App und der Testprozess taten es
  nicht, und `FrameChannel`s `SO_NOSIGPIPE` deckt nur Sockets — nicht die
  Pipes, über die `ProcessRunner` mit Kindprozessen spricht, wo diese Option
  nicht gilt.

  Aufgefallen ist das, weil der Release-Workflow zweimal mit
  `exited with unexpected signal code 13` abbrach, während mehrere
  prozessstartende Tests gleichzeitig liefen. Die genaue Schreiboperation habe
  ich **nicht** identifiziert; dies ist daher ausdrücklich nicht als bewiesene
  Behebung dieses Vorfalls dargestellt. Es entfernt eine Fehlermöglichkeit, die
  in einem Prozess, der auf fremdgesteuerte Pipes und Sockets schreibt, ohnehin
  nicht bestehen sollte.

  Beim Testen dieser Änderung habe ich den Fehler dann lokal reproduziert — und
  zwar selbst verursacht: meine ersten Testfassungen setzten `SIGPIPE`
  prozessweit zurück, um zu prüfen, ob `ProcessRunner` es wieder einrichtet.
  Unter `--parallel` schrieb in diesem Fenster ein nebenläufiger Test in eine
  gebrochene Pipe und riss den Lauf mit. Dieselbe Fehlerklasse wie die `umask`
  im Socket-Aufbau: **prozessweiter Zustand, der aus einem Test heraus
  umgeschaltet wird.** Die Aufrufstellen werden jetzt am Quelltext geprüft, und
  ein Test verbietet, dass irgendein Test die Disposition umschaltet.

- **Das erste Release lief nur auf der Maschine, die es gebaut hat.**
  v0.1.0-rc.1 war signiert, hatte eine gültige SHA-256 und eine gültige
  Ed25519-Signatur — und stürzte auf jedem anderen Mac beim Start ab.
  Zurückgezogen.

  SwiftPM erzeugt je Build-System einen anderen Zugriffscode für
  `Bundle.module`. Der des **nativen** Systems prüft genau zwei Pfade: das
  Wurzelverzeichnis des `.app` und den **absoluten Pfad des
  Build-Verzeichnisses**, als Zeichenkette einkompiliert. Im veröffentlichten
  Archiv stand entsprechend
  `/Users/runner/work/biscuit/biscuit/.build/…/Biscuit_BiscuitKit.bundle`.
  Ins Wurzelverzeichnis darf das Ressourcen-Bundle nicht, weil das die
  Code-Signatur bricht (`unsealed contents present in the bundle root`,
  gemessen). Lokal galt das Xcode-Build-System, in der CI das native — daher
  grün hier und kaputt dort.

  **Schlimmer als der Fehler war mein erster Versuch, ihn zu beheben.** Die CI
  meldete „Zeichenkettentabelle für 'en' fehlt im Bundle" — ein zutreffender
  Befund. Ich habe die Prüfung nachsichtig gemacht, sodass sie beide Layouts
  akzeptierte, und damit die Meldung zum Schweigen gebracht statt die Ursache
  behoben. Die CI wurde grün, das Release kaputt.

  Auch der zweite Versuch scheiterte, und wieder an derselben Denkform: ich
  prüfte, *ob* `--build-system` existiert, nicht welche Werte sie annimmt. Die
  Namen unterscheiden sich zwischen Toolchains (`swiftbuild` hier, `native`,
  `next` oder `xcode` auf dem Runner), und rc.2 brach mit
  `The value 'swiftbuild' is invalid` ab. Jetzt werden die Kandidaten
  durchprobiert; `native` steht bewusst nicht darunter.

  Auch der dritte Versuch — ein anderes Build-System erzwingen — trug nicht:
  auf der Toolchain des CI-Runners erzeugt `next` denselben Zugriffscode wie
  `native`, und `xcode` bricht mit „duplicate output file" ab. **Kein**
  Build-System dort liefert ein eigenständiges Binary.

  Behoben ist es daher an der Ursache: die gepackte App trägt ihre
  Sprachtabellen jetzt in `Contents/Resources/<lang>.lproj` — der gewöhnlichen
  Stelle einer macOS-App — und `L10n` sucht dort zuerst. Nachgewiesen: mit
  gelöschtem Ressourcen-Bundle startet die App in beiden Sprachen.

  Dabei fiel ein zweiter, davon unabhängiger Fehler auf: **der Helfer konnte die
  Tabellen nie finden.** `biscuit-helper` ist ein eigenes Executable in
  `Contents/MacOS`, seine `Bundle.main` *ist* dieses Verzeichnis, und jeder
  Kandidat des Zugriffscodes zeigt dorthin — das Bundle lag in
  `Contents/Resources`. Jede lokalisierte Fehlermeldung im Helfer wäre ein
  `fatalError` gewesen, als Root, mitten im Beschreiben eines Datenträgers.
  Dieselbe Auflösung behebt beides.

- **Der Katalog wäre in jedem gepackten Build tot gewesen.**
  `Scripts/bundle.sh` schreibt alle `Biscuit*`-Schlüssel in die `Info.plist` und
  lässt die nicht gesetzten als **leeren String** stehen. Der Schlüssel
  existiert damit, `as? String` liefert `""` statt `nil`, und ein
  `?? fallback` greift nie.

  `catalogueBaseURL` las `BiscuitCatalogueURL`, fand `""`, baute
  `URL(string: "")` — was `nil` ist — und fiel auf `https://example.invalid/`
  zurück. Der Zweig, der die echte GitHub-Pages-Adresse ableitet, war
  unerreichbar. Nachgemessen mit der Logik und dem Wert aus dem gebauten
  Bundle, nicht erschlossen.

  Die Lesefunktion behandelt leer und Weißraum jetzt als fehlend, und die
  Logik liegt als `BundleConfiguration` in BiscuitKit, wo sie geprüft werden
  kann — `AppInfo` steckt in einem Executable-Target, das das Testziel nicht
  importieren kann. Elf Tests, darunter einer, der die abgeleitete Adresse
  gegen die tatsächlich eingerichtete Pages-Adresse festnagelt, und einer, der
  verhindert, dass ein `Biscuit*`-Schlüssel wieder direkt gelesen wird.

- **`JobExecutor`s beide Vorbedingungen hatten keinen einzigen Test.**
  `assertAnswerFileApplies` und `assertSourceMatchesStrategy` waren private
  Statics in einem Executable-Target, das das Testziel nicht importieren kann —
  und sie bewachen den Moment unmittelbar vor dem Löschen eines Datenträgers.
  Beide liegen jetzt auf `JobRequest` in BiscuitKit. Acht Tests, darunter ein
  erschöpfender über alle 16 Strategie-Quellen-Paarungen: der `default`-Zweig
  ist das, was eine später ergänzte Strategie abfängt, und eine unvollständige
  Prüfung würde eine Fehlpaarung bis zum Löschschritt durchlassen.

- **Die Systemdatenträger-Schranke ließ sich mit einer gebastelten Kennung
  umgehen.** `normaliseWholeDisk` gab jede Eingabe, die nicht mit `disk` begann,
  **unverändert** zurück — und `diskutil info -plist` nimmt auch Einhängepunkte
  an. Nachgemessen: `diskutil info -plist /` endet mit 0 und beschreibt das
  laufende Systemvolume.

  Die Folge war mehr als eine schiefe Protokollzeile. `StorageDevice.bsdName`
  wurde aus dieser Eingabe gesetzt, und `isSystemDisk` wird als
  `systemDisks.contains(bsdName)` gegen normalisierte Namen wie `disk3`
  berechnet. `"/"` steht dort nicht drin — die eigens dafür gebaute Schranke
  meldete also **false für den Systemdatenträger selbst**.

  Auf einem intern gebooteten Mac fing die Eignungsprüfung das hinterher
  zufällig ab, weil die interne Platte weder wechselbar noch auswerfbar ist.
  **Auf einem von externer SSD gebooteten Mac** — bei älteren Geräten und
  Testaufbauten üblich — meldet `/` sich als extern und auswerfbar, beide
  Schranken fallen, und das Ziel ist der laufende Systemdatenträger.

  Zwei unabhängige Schichten jetzt: eine Formprüfung auf `r?diskN(sN)*` vor dem
  `diskutil`-Aufruf, und der Gerätename wird aus dem gemeldeten
  `DeviceIdentifier` abgeleitet statt aus der Anfrage, mit Abbruch bei
  Abweichung. Nachgewiesen, dass beide tragen: mit entfernter Formprüfung fängt
  die zweite Schicht denselben Fall. Elf Tests, darunter drei gegen das echte
  `diskutil` — einer prüft ausdrücklich, dass `diskutil` Einhängepunkte
  *weiterhin* annimmt, damit die Begründung dieses Codes nicht stillschweigend
  veraltet.

- **Der Client konnte bestimmen, welches Programm als Root läuft.**
  `JobRequest.wimToolPath` wird von der unprivilegierten App gewählt und war das
  Executable eines Root-Kindprozesses. `locate(preferring:)` setzte den Pfad an
  die *erste* Stelle der Kandidatenliste, und die einzige Prüfung auf dem Weg
  bis `Process.executableURL` war `isExecutableFile`.

  Quellpfade in derselben Anfrage werden seit immer gegen eine Allow-List
  geprüft, genau aus diesem Grund — der Werkzeugpfad hatte diese Behandlung nur
  nie bekommen. Die dokumentierte Grenze zum Sitzungstoken deckt es nicht ab:
  sie argumentiert, ein solcher Angreifer könne auch selbst einen Admin-Dialog
  zeigen. Hier war kein Dialog nötig, weil der Benutzer *Biscuit* freigegeben
  hatte, nicht ein beliebiges Programm.

  Jetzt prüft `validateToolPath` Basename, Verzeichnis, Traversal sowie
  Schreibrechte von Datei **und** Verzeichnis; das mitgelieferte wimlib findet
  der Helfer über seinen eigenen Pfad statt über die Anfrage. Die unsichere
  `locate(preferring:)` ist entfernt, nicht als veraltet markiert — 17 Tests
  halten das fest, zwei davon die Aufrufstelle und einer die Abwesenheit der
  alten Funktion. Die verbleibende Grenze (benutzereigenes Homebrew auf Apple
  Silicon) steht als Punkt 7 in SECURITY.md.

- **Der Helfer prüfte Antwortdateien nicht wirklich nach.** Über dem Code stand
  „re-validated here rather than trusted from the app", geprüft wurde aber
  `answerFile.isUsable` — und `isUsable` wird aus `findings` berechnet, das als
  Teil der `Codable`-Darstellung **mit über die Leitung kommt**. Ein Client, der
  `findings: []` sendet, erklärte damit seine eigene Datei für in Ordnung, und
  der Helfer nahm ihn beim Wort. Der Kommentar beschrieb eine Absicht, nicht den
  Code. Jetzt leitet `assertWritable()` das Urteil aus den Bytes ab, und die
  Größengrenze greift unabhängig von jedem Befund. Elf Tests halten die
  Vertrauensgrenze fest, zwei davon prüfen die Aufrufstelle im Helfer selbst.

  Gegengeprüft: `validateTarget` macht es richtig — `isSystemDisk` und
  `isEligibleTarget` kommen unabhängig aus `diskutil`, und die übertragene
  Gerätegröße dient nur als Drift-Prüfung, kann also nur zur Ablehnung führen,
  nie zur Erlaubnis.

- **Neun Diagnosen waren auf Deutsch.** Die Projektregel lautet: benutzersichtbarer
  Text wird lokalisiert, Diagnosen bleiben englisch und unlokalisiert, damit zwei
  Nutzer beim selben Fehler vergleichbare Berichte erzeugen und eine Zeichenkette
  suchbar bleibt. Betroffen war unter anderem die Meldung beim vertauschten
  Datenträger — genau die, die ein Fehlerbericht am ehesten zitieren würde.
  Eine Stichprobe per Suche fand vier der neun; die übrigen fünf standen auf
  Fortsetzungszeilen und im Startpfad des Helfers. Ein Test prüft das jetzt
  vollständig und fand dabei einen zehnten.

- **Englische Nutzer sahen an einer Stelle deutschen Text.** `OutcomeSection`
  zeigte einen in Swift fest eincodierten deutschen Starthinweis, während der
  Schlüssel `ui.outcome.windows_boot_hint` in beiden Sprachen vorlag und von
  niemandem verwendet wurde. Weder der Compiler noch die
  Vollständigkeitsprüfung konnten das sehen: der Schlüssel war in beiden
  Sprachen vorhanden, also galt die Lokalisierung als vollständig, und ein
  fest eincodiertes Literal ist einwandfreies Swift.

  Die Signatur dieses Fehlers ist ein **unbenutzter** Schlüssel, und darauf
  prüft jetzt ein Test. Er brachte außerdem 13 weitere unbenutzte Schlüssel zum
  Vorschein: sieben Fehlerschlüssel, die von den Komfort-Konstruktoren auf
  `BiscuitError` überholt waren (die ihre eigene lokalisierte Meldung
  mitbringen), drei Antwortdatei-Funde, welche die Oberfläche bewusst
  zusammenfasst, sowie drei weitere Überreste. Alle gelöscht statt
  entschuldigt — die Ausnahmeliste des Tests ist leer.

- **Ein solid-komprimiertes `install.wim` wäre mitten im Schreiben gescheitert.**
  Der Inspector entschied „teilen oder konvertieren" nach der Dateiendung:
  `.wim` teilbar, `.esd` nicht. Nachgemessen gegen wimlib 1.14.5 ist das falsch —
  `wimlib-imagex split` lehnt solide Ressourcen mit Exit 68 ab
  („Splitting of WIM containing solid resources is not supported"), und solche
  `.wim`-Dateien entstehen regulär durch `dism /compress:recovery` sowie durch
  UUP-basierte ISO-Bauer. Die Ablehnung wäre erst gekommen, als das Medium schon
  teilweise beschrieben war.

  Erschwerend: die Kompressionsart im **Header** genügt zur Unterscheidung
  nicht. Ein solides und ein nicht-solides LZMS-Abbild tragen identische
  Header-Flaggen (`0x00080082`), und nur eines lässt sich teilen. Entscheidend
  ist Bit `0x10` auf den einzelnen Deskriptoren der Blob-Tabelle. Genau das wird
  jetzt gelesen; bei unlesbarer Tabelle gilt „nicht teilbar", weil ein falsches
  „konvertieren" Zeit kostet und ein falsches „teilen" den Auftrag.

- **Ein `WIMCompression.none` fragte in Wahrheit nach `nil`.** Auf einem
  optionalen `WIMCompression?` löst ein nacktes `.none` zu `Optional.none` auf,
  nicht zum Enum-Fall. `compression == .none` prüfte damit, ob der Wert `nil`
  ist — und ein Test bestand aus diesem Grund. Der Fall heißt jetzt
  `uncompressed`, womit die Verwechslung sprachlich unmöglich ist.

- **Ein Test bestand aus dem falschen Grund.** „Eine absurde XML-Größe wird
  abgelehnt" prüfte nur, *dass* ein Fehler fliegt. Die Fixture setzte aber bloß
  das Größenfeld und nicht das Feld für die unkomprimierte Größe, sodass vorher
  die Prüfung auf Größengleichheit zuschlug — die 16-MiB-Obergrenze, um die es
  ging, wurde nie ausgeführt. Aufgefallen erst, als ein Integrationstest eine
  andere Meldung erwartete als die, die tatsächlich kam. Jetzt prüfen alle drei
  Ablehnungstests, *welche* Kontrolle angesprochen hat.

- **Ein Test suchte „solid" in Text, der den Eingabepfad enthielt.** Der
  Abgleich mit wimlib entschied anhand eines Teilstrings der Ausgabe — und die
  Erfolgsmeldung enthält den Dateinamen, der im Fixture
  `compress-lzms-nonsolid.wim` das Wort enthält. Ein erfolgreicher Durchlauf
  wurde dadurch als Ablehnung gewertet. Jetzt entscheidet der Exit-Code, und
  bei Fehlschlag wird auf genau 68 geprüft, damit kein anderer Fehler sich als
  Solid-Ablehnung ausgeben kann.

- **Der Katalog-Browser war aus der Oberfläche nicht erreichbar.**
  `SourceSection` setzte eine `showCatalogue`-Flagge, aber es war nie ein
  `.sheet` daran gebunden. Der Verweis „Katalog öffnen" tat schlicht nichts, und
  damit war der gesamte Katalog — Download, Prüfsummenkette, Provenance-Anzeige,
  der macOS-Reiter — toter Code in einem Programm, das sonst fehlerfrei lief.
  Der Compiler schweigt dazu, weil ein `@State Bool`, den niemand liest,
  einwandfreies Swift ist, und Unit-Tests schweigen auch: jede Ansicht für sich
  war richtig, nur die Verbindung fehlte. Abgesichert ist das jetzt durch einen
  Test, der den Quelltext der Ansichten liest und für jede auf `true` gesetzte
  Präsentationsflagge einen auswertenden Modifier verlangt.

- **`make app` scheiterte auf jedem Baum ohne Git-Tags.** Die Versionsnummer kam
  aus `git describe … | sed 's/^v//' || echo 0.0.0-dev`. Der Exit-Status einer
  Pipeline ist aber der des *letzten* Glieds, und `sed` ist mit leerer Eingabe
  erfolgreich — der Fallback feuerte nie und `--version` wurde leer an
  `bundle.sh` übergeben, das mit `unknown option` abbrach. Betroffen war jeder
  Tarball-Download und jeder frische Klon vor dem ersten Tag; die
  Nachbarzeile für `BUILD` war zufällig korrekt, weil dort keine Pipe steht.
  Jetzt wird auf die leere Variable geprüft, nicht auf den Exit-Status.

- **Der Aufbau des Helfer-Sockets machte fremde Verzeichnisse unbeschreibbar.**
  `UnixSocket.listen` setzte `umask(0o177)` um `bind` herum, um den Socket-Knoten
  gleich mit engen Rechten anzulegen — das Lehrbuchvorgehen. Aber `umask` gilt
  **pro Prozess, nicht pro Thread**: jedes Verzeichnis, das ein anderer Thread in
  diesem Fenster anlegte, entstand ohne Ausführungsbit, und das Schreiben darin
  scheiterte anschließend mit `EPERM` — weit entfernt von der Socket-Stelle und
  lange nachdem die Maske zurückgesetzt war. Aufgefallen als Test in einer
  *anderen* Suite, der eine Datei nicht in ein Verzeichnis schreiben konnte, das
  er gerade erfolgreich erzeugt hatte; etwa ein Durchlauf von dreißig.
  Die Maske war ersatzlos entbehrlich, weil die Zusage nicht an ihr hängt: der
  Socket entsteht im Sitzungsverzeichnis, das mit 0700 angelegt wird und das
  `HelperSessionValidator` nur akzeptiert, solange es exakt 0700 und richtig
  besessen ist. Kein anderer Nutzer kann hineinwechseln, also ist das Fenster
  zwischen `bind` und `chmod` nicht erreichbar.

- **`ProcessRunner` hing bei jedem länger laufenden Werkzeug.**
  `Process.waitUntilExit()` blockiert den aufrufenden Thread; in einem
  `async`-Kontext ist das ein Thread des Cooperative-Pools. Ab
  `activeProcessorCount` gleichzeitigen Aufrufen ist der Pool erschöpft und
  **kein `Task` kann mehr laufen — auch der Timeout-Watchdog nicht.** Gemessen:
  0 von 24 Watchdogs feuerten innerhalb des vierfachen Zeitlimits. Kurze Befehle
  wie `diskutil info` verdeckten das vollständig. Betroffen wären
  `diskutil eraseDisk`, `wimlib-imagex` und `createinstallmedia` gewesen — jeder
  reale Vorgang, mitten im Schreiben, ohne Abbruchmöglichkeit.

- **`FileTreeCopier` konnte den Verzeichnisbaum flachklopfen.** Relative Pfade
  wurden per String-Prefix berechnet. Löst macOS einen Symlink auf — `/var/…`
  gegenüber `/private/var/…` — fiel jede Datei auf ihren Basisnamen zurück. Auf
  einem Windows-Stick wäre `EFI/BOOT/BOOTX64.EFI` im Wurzelverzeichnis gelandet;
  die Firmware hätte den Stick übersprungen.

- **Kein Fortschritt während der WIM-Zerlegung.** `wimlib-imagex` schreibt seine
  Meldungen auf **stderr**; beobachtet wurde nur stdout. Der Balken wäre bei
  einem echten `install.wim` über zehn Minuten eingefroren.

- **Der Accept-Timeout des Helfers griff nicht.** Auf Darwin weckt `shutdown(2)`
  einen in `accept(2)` blockierten Thread **nicht**, und `close(2)` weckt ihn mit
  `ECONNABORTED`, nicht mit `EBADF`. Der Timeout wurde dadurch zu einem
  geworfenen Fehler statt zu einem kontrollierten Abbruch.

- **Library Validation blockierte das eingebettete wimlib.** Ad-hoc-Signaturen
  haben keine Team-ID; dyld verweigerte die mitgelieferte dylib und macOS
  beendete den Prozess mit SIGKILL. Behoben durch korrekte Signier-Reihenfolge
  und ein eng gefasstes Entitlement.

- **`dup()` und `/dev/fd/N` teilen unter macOS den Dateioffset.** Anders als
  unter Linux erzeugt `/dev/fd/N` keine neue Dateibeschreibung. Der Helfer hätte
  nach dem Entpacken von der falschen Position weitergelesen. Gelöst mit einer
  `pread`-basierten libarchive-Quelle, die ihren Offset selbst führt.

- **libarchive meldet beschädigte gzip-Ströme nicht.** Gemessen: Gute und
  manipulierte Datei liefern beide die volle Bytezahl und „kein Fehler". Für xz,
  bzip2 und zstd wird Korruption erkannt, für gzip nicht. Biscuit prüft die
  CRC-32 aus dem gzip-Trailer jetzt selbst.

- **Fedora fiel aus dem Katalog.** Zwei Ursachen gleichzeitig:
  `download.fedoraproject.org` ist ein Redirector ohne Verzeichnislisting, und
  Fedora nutzt das BSD-Format `SHA256 (datei) = hash` statt `hash  datei`. Der
  Parser meldete „Datei nicht gelistet" statt „Format nicht verstanden".

- **Ein Test-Ziel mit eigenen Ressourcen verdeckt `Bundle.module` des Kits.** Die
  Lokalisierungstests suchten plötzlich im falschen Bundle und meldeten jeden
  Schlüssel als fehlend.

- Kleinere Funde: ein `var hasher`, der über eine Kopie mutiert wurde (der Hash
  wäre falsch gewesen); ein Platzhalter-Parser im Test, der `%1$@` nicht erkannte
  und stillschweigend Müll verglich; ein als parametrisiert deklarierter
  Schlüssel ohne Platzhalter.
