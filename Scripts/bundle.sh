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
for language in en de; do
  strings_file="$APP/Contents/Resources/Biscuit_BiscuitKit.bundle/Contents/Resources/$language.lproj/Localizable.strings"
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

log "Fertig: $APP"
log "Version $VERSION ($BUILD_NUMBER)"
codesign -dv "$APP" 2>&1 | sed 's/^/    /'
