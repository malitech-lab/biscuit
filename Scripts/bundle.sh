#!/bin/bash
#
# Builds Biscuit.app from the SwiftPM products.
#
# SwiftPM cannot emit an application bundle, so this assembles one: it compiles
# the two executables, lays out Contents/, substitutes the Info.plist template,
# optionally vendors wimlib, and ad-hoc signs the result.
#
#   Scripts/bundle.sh [--release|--debug] [--version X.Y.Z] [--build N]
#                     [--vendor-wimlib] [--sign-identity NAME] [--output DIR]
#
# Environment:
#   BISCUIT_UPDATE_REPO     GitHub owner/repo used for update checks
#   BISCUIT_UPDATE_PUBKEY   base64 Ed25519 public key releases must be signed with
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CONFIGURATION="release"
VERSION=""
BUILD_NUMBER=""
VENDOR_WIMLIB="no"
SIGN_IDENTITY="-"
OUTPUT_DIR="$ROOT/dist"
BUNDLE_ID="dev.biscuit.Biscuit"

while [ $# -gt 0 ]; do
  case "$1" in
    --release)        CONFIGURATION="release"; shift ;;
    --debug)          CONFIGURATION="debug"; shift ;;
    --version)        VERSION="$2"; shift 2 ;;
    --build)          BUILD_NUMBER="$2"; shift 2 ;;
    --vendor-wimlib)  VENDOR_WIMLIB="yes"; shift ;;
    --sign-identity)  SIGN_IDENTITY="$2"; shift 2 ;;
    --output)         OUTPUT_DIR="$2"; shift 2 ;;
    --bundle-id)      BUNDLE_ID="$2"; shift 2 ;;
    -h|--help)        sed -n '2,20p' "$0"; exit 0 ;;
    *)                echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Version
# ---------------------------------------------------------------------------

if [ -z "$VERSION" ]; then
  if git -C "$ROOT" describe --tags --abbrev=0 >/dev/null 2>&1; then
    VERSION="$(git -C "$ROOT" describe --tags --abbrev=0 | sed 's/^v//')"
  else
    VERSION="0.0.0-dev"
  fi
fi

if [ -z "$BUILD_NUMBER" ]; then
  if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
  else
    BUILD_NUMBER="1"
  fi
fi

UPDATE_REPO="${BISCUIT_UPDATE_REPO:-malitech-lab/biscuit}"
UPDATE_PUBKEY="${BISCUIT_UPDATE_PUBKEY:-}"
CATALOGUE_URL="${BISCUIT_CATALOGUE_URL:-}"

if [ -z "$UPDATE_PUBKEY" ]; then
  warn "BISCUIT_UPDATE_PUBKEY ist nicht gesetzt — automatische Updates bleiben in diesem Build deaktiviert."
fi

# ---------------------------------------------------------------------------
# SDK selection
#
# In macOS 15.4+ SDKs, SwiftUI's @State is an attached macro whose plugin
# (SwiftUIMacros) ships only with full Xcode. On a machine that has just the
# Command Line Tools, compiling against such an SDK fails outright. Falling back
# to the newest SDK that still declares @State as a property wrapper keeps the
# project buildable without a 10 GB Xcode download. CI, which has Xcode, takes
# the first branch.
# ---------------------------------------------------------------------------

select_sdk() {
  if [ -n "${SDKROOT:-}" ]; then
    log "SDKROOT aus Umgebung: $(basename "$SDKROOT")"
    return
  fi

  local chosen
  chosen="$("$ROOT/Scripts/select-sdk.sh" 2>/dev/null || true)"
  if [ -n "$chosen" ]; then
    export SDKROOT="$chosen"
    warn "Kein SwiftUI-Makro-Plugin gefunden (nur Command Line Tools installiert)."
    warn "Baue stattdessen gegen $(basename "$SDKROOT")."
  fi
}

select_sdk

# ---------------------------------------------------------------------------
# Compile
# ---------------------------------------------------------------------------

log "Baue Biscuit $VERSION ($BUILD_NUMBER), Konfiguration: $CONFIGURATION"
# Das Build-System wird ausdrücklich gewählt, nicht der Toolchain überlassen.
#
# SwiftPM erzeugt je Build-System einen anderen Zugriffscode für
# `Bundle.module`. Der des nativen Systems kompiliert den absoluten Pfad des
# Build-Verzeichnisses ein und sucht sonst nur im Wurzelverzeichnis des .app —
# wohin das Ressourcen-Bundle nicht darf, weil es die Signatur bricht. Ergebnis:
# ein Bundle, das auf der Baumaschine läuft und sonst nirgends. Genau so ist
# v0.1.0-rc.1 entstanden, weil lokal und in der CI unterschiedliche Vorgaben
# galten.
#
# Fehlt die Option in der Toolchain, wird ohne sie gebaut; die
# Eigenständigkeitsprüfung weiter unten bricht dann ab, statt ein kaputtes
# Bundle auszuliefern.
# Bewusst keine Wahl des Build-Systems.
#
# Drei Versuche, eines zu erzwingen, sind gescheitert — jeder an derselben
# Denkform, Verfügbarkeit statt Eignung zu prüfen:
#
#   1. Nur geprüft, *ob* `--build-system` existiert → der Runner lehnte den Wert
#      'swiftbuild' ab.
#   2. Kandidaten durchprobiert → 'next' wurde angenommen, erzeugt aber denselben
#      Zugriffscode wie 'native'.
#   3. Mit `--show-bin-path` geprobt → das baut nicht, also bestand 'xcode' die
#      Probe und scheiterte erst im echten Build an "duplicate output file".
#
# Nötig war das alles nur, weil die Lokalisierung aus dem SwiftPM-Ressourcen-
# Bundle las, dessen Lage vom Build-System abhängt. Das liest sie nicht mehr:
# die Tabellen liegen in Contents/Resources. Damit ist das Build-System
# gleichgültig, und die Vorgabe der Toolchain ist die richtige Wahl.
swift build -c "$CONFIGURATION" --product Biscuit
swift build -c "$CONFIGURATION" --product biscuit-helper

BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
[ -x "$BIN_DIR/Biscuit" ] || die "Biscuit nicht gefunden in $BIN_DIR"
[ -x "$BIN_DIR/biscuit-helper" ] || die "biscuit-helper nicht gefunden in $BIN_DIR"

# ---------------------------------------------------------------------------
# Lay out the bundle
# ---------------------------------------------------------------------------

APP="$OUTPUT_DIR/Biscuit.app"
log "Erzeuge $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

install -m 0755 "$BIN_DIR/Biscuit" "$APP/Contents/MacOS/Biscuit"
install -m 0755 "$BIN_DIR/biscuit-helper" "$APP/Contents/MacOS/biscuit-helper"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
  log "Erzeuge App-Icon"
  swift "$ROOT/Scripts/make-icon.swift" "$ROOT/Resources"
fi
install -m 0644 "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM emits the localised string tables as a resource bundle that
# `Bundle.module` looks for next to the executable. Without this the app runs but
# every label shows its raw key, so a missing bundle is a hard failure.
BUNDLE_COUNT=0
for resource_bundle in "$BIN_DIR"/*.bundle; do
  [ -d "$resource_bundle" ] || continue
  log "Binde Ressourcen ein: $(basename "$resource_bundle")"
  rm -rf "$APP/Contents/Resources/$(basename "$resource_bundle")"
  cp -R "$resource_bundle" "$APP/Contents/Resources/"
  BUNDLE_COUNT=$((BUNDLE_COUNT + 1))
done
[ "$BUNDLE_COUNT" -gt 0 ] || die "Kein Ressourcen-Bundle in $BIN_DIR gefunden — die Oberfläche würde nur Schlüssel anzeigen."

# Verify both languages actually made it in.
#
# The claim I got wrong once, written down so it is not repeated: `Bundle.module`
# does **not** cope with any layout. SwiftPM generates a different accessor per
# build system, and the two look in different places.
#
#   Xcode build system  → Bundle.main.resourceURL  (= Contents/Resources), and
#                          Bundle.main.bundleURL as a later fallback
#   native build system → Bundle.main.bundleURL only (= the .app itself)
#
# Only `Contents/Resources` is usable, because a bundle sitting in the root of a
# .app breaks the code signature: `codesign --verify` then reports "unsealed
# contents present in the bundle root". Measured, not assumed.
#
# So the layout is not a choice. If the binary was built by the native build
# system it will look in the wrong place, and the launch check below is what
# catches that — a file existing at a path this script guessed proves nothing.
# Die Sprachtabellen zusätzlich direkt nach Contents/Resources legen — dorthin,
# wo eine macOS-App sie normalerweise trägt.
#
# Das Ressourcen-Bundle allein genügt nicht. Der Helfer ist ein eigenes
# Executable in Contents/MacOS; seine Bundle.main *ist* dieses Verzeichnis, und
# jeder Kandidat des generierten Zugriffscodes zeigt dorthin, während das
# Ressourcen-Bundle in Contents/Resources liegt. Eine lokalisierte Meldung im
# Helfer wäre damit ein fatalError — als Root, mitten im Schreiben. Und die
# Lage innerhalb des Ressourcen-Bundles hängt vom Build-System ab.
#
# L10n.resolvedResourceBundle sucht deshalb zuerst hier.
for lproj in "$APP/Contents/Resources/Biscuit_BiscuitKit.bundle"/Contents/Resources/*.lproj \
             "$APP/Contents/Resources/Biscuit_BiscuitKit.bundle"/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

for language in en de; do
  # Geprüft wird die Stelle, aus der die App tatsächlich liest.
  strings_file="$APP/Contents/Resources/$language.lproj/Localizable.strings"
  [ -f "$strings_file" ] || die "Zeichenkettentabelle für '$language' fehlt im Bundle"
  plutil -lint "$strings_file" >/dev/null || die "Zeichenkettentabelle für '$language' ist ungültig"
done
log "Sprachen im Bundle: en, de"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Substitute the Info.plist template. sed is used with a delimiter that cannot
# appear in a base64 key or a repository slug.
COPYRIGHT="© $(date +%Y) Biscuit contributors. GPL-3.0-or-later."
sed \
  -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
  -e "s|@VERSION@|$VERSION|g" \
  -e "s|@BUILD@|$BUILD_NUMBER|g" \
  -e "s|@UPDATE_REPO@|$UPDATE_REPO|g" \
  -e "s|@UPDATE_PUBKEY@|$UPDATE_PUBKEY|g" \
  -e "s|@CATALOGUE_URL@|$CATALOGUE_URL|g" \
  -e "s|@COPYRIGHT@|$COPYRIGHT|g" \
  "$ROOT/Resources/Info.plist.in" > "$APP/Contents/Info.plist"

plutil -lint "$APP/Contents/Info.plist" >/dev/null || die "Info.plist ist ungültig"

# ---------------------------------------------------------------------------
# wimlib
# ---------------------------------------------------------------------------

if [ "$VENDOR_WIMLIB" = "yes" ]; then
  log "Binde wimlib ein"
  "$ROOT/Scripts/vendor-wimlib.sh" "$APP" || \
    warn "wimlib konnte nicht eingebunden werden; die App nutzt zur Laufzeit Homebrew."
fi

# ---------------------------------------------------------------------------
# Signing
#
# "-" is an ad-hoc signature: it establishes code identity for the current
# machine but carries no certificate, so Gatekeeper will not vouch for the app
# on another Mac. That is deliberate and documented — see README, "Installation".
# ---------------------------------------------------------------------------

log "Signiere mit Identität: $SIGN_IDENTITY"

# Strict inside-out order. Signing an executable before the libraries it loads
# leaves the executable sealed against a signature that is then replaced, and
# dyld rejects the result at launch.
for dylib in "$APP"/Contents/Frameworks/*.dylib; do
  [ -f "$dylib" ] || continue
  codesign --force --timestamp=none --options runtime \
    --sign "$SIGN_IDENTITY" "$dylib"
done

if [ -x "$APP/Contents/MacOS/wimlib-imagex" ]; then
  # Needs library validation disabled: it loads a bundled dylib, and an ad-hoc
  # signature carries no Team ID for the two to agree on. See the entitlements
  # file for the full reasoning.
  codesign --force --timestamp=none --options runtime \
    --entitlements "$ROOT/Resources/wimlib.entitlements" \
    --sign "$SIGN_IDENTITY" "$APP/Contents/MacOS/wimlib-imagex"
fi

codesign --force --timestamp=none \
  --options runtime \
  --sign "$SIGN_IDENTITY" \
  "$APP/Contents/MacOS/biscuit-helper"

codesign --force --timestamp=none \
  --options runtime \
  --sign "$SIGN_IDENTITY" \
  "$APP"

codesign --verify --deep --strict "$APP" || die "Signaturprüfung fehlgeschlagen"

# A vendored tool that cannot launch is worse than none: the app would offer
# Windows media creation and then fail part-way through. Verified here so the
# build fails instead.
if [ -x "$APP/Contents/MacOS/wimlib-imagex" ]; then
  if WIMLIB_VERSION="$("$APP/Contents/MacOS/wimlib-imagex" --version 2>&1 | head -1)"; then
    log "Eingebettetes wimlib startet: $WIMLIB_VERSION"
  else
    die "Das eingebettete wimlib-imagex startet nach dem Signieren nicht."
  fi
fi

# Group- or world-writable bits on the helper would let a non-admin replace the
# binary that the app later runs as root.
chmod 755 "$APP/Contents/MacOS/biscuit-helper"
find "$APP" -perm -o+w -print0 | while IFS= read -r -d '' entry; do
  warn "Entferne Schreibrecht für andere: $entry"
  chmod o-w "$entry"
done

# Hängt das Binary noch am Build-Verzeichnis?
#
# Früher war das tödlich: v0.1.0-rc.1 suchte sein Ressourcen-Bundle über einen
# einkompilierten absoluten Build-Pfad und stürzte auf jedem anderen Mac ab.
# Inzwischen liest die Lokalisierung aus Contents/Resources und der einzige
# andere Zugriff auf Bundle.module ist der Rückfall, der dann nicht mehr läuft —
# die Prüfung weiter oben stellt sicher, dass die Tabellen dort liegen.
#
# Deshalb nur noch ein Hinweis, keine Abbruchbedingung: die Ursache ist behoben,
# nicht bloß die Meldung. Bliebe es ein Fehler, würde der Paketlauf auf
# Toolchains scheitern, auf denen kein Build-System ein eigenständiges Binary
# erzeugt — und das ohne Not, weil die App ohne dieses Bundle läuft.
if strings "$APP/Contents/MacOS/Biscuit" 2>/dev/null \
   | grep -q "\.build/.*Biscuit_BiscuitKit\.bundle"; then
  warn "Das Binary nennt noch einen Build-Pfad für das Ressourcen-Bundle."
  warn "Unkritisch, solange Contents/Resources die Sprachtabellen enthält (oben geprüft)."
else
  log "Binary nennt keinen Build-Pfad"
fi

# Startprobe. Zusätzlich, nicht stattdessen.
#
# Ein v0.1.0-rc.1 wurde veröffentlicht, signiert, mit gültiger Prüfsumme — und
# stürzte beim Start ab, weil das Ressourcen-Bundle dort lag, wo dieses Skript
# es erwartete, und nicht dort, wo das gebaute Binary danach sucht. Jede
# bisherige Prüfung hier sah nach, ob Dateien an geratenen Pfaden liegen. Keine
# hat das Programm gestartet.
#
# Gestartet wird ohne Fenster-Interaktion: die App legt ihre Umgebung an, lädt
# Lokalisierung und Katalogzustand und bleibt dann am Leben. Stürzt sie vorher,
# bricht das Paket ab.
log "Startprobe"
SMOKE_LOG="$(mktemp -t biscuit-smoke)"
"$APP/Contents/MacOS/Biscuit" -AppleLanguages "(en)" >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
SMOKE_OK="no"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  if ! kill -0 "$SMOKE_PID" 2>/dev/null; then break; fi
done
if kill -0 "$SMOKE_PID" 2>/dev/null; then
  SMOKE_OK="yes"
  kill "$SMOKE_PID" 2>/dev/null || true
  wait "$SMOKE_PID" 2>/dev/null || true
fi
if [ "$SMOKE_OK" != "yes" ]; then
  warn "Die App hat sich beim Start beendet. Ausgabe:"
  sed 's/^/    /' "$SMOKE_LOG" >&2
  rm -f "$SMOKE_LOG"
  die "Startprobe fehlgeschlagen — das Bundle ist nicht lauffähig.
  Prüfe die Ausgabe oben. Enthält sie \"could not find bundle\" oder
  \"unable to find bundle\", fehlen die Sprachtabellen in Contents/Resources;
  L10n liest dort zuerst und fällt nur in Tests auf Bundle.module zurück."
fi
rm -f "$SMOKE_LOG"
log "Startprobe bestanden"

log "Fertig: $APP"
log "Version $VERSION ($BUILD_NUMBER)"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
