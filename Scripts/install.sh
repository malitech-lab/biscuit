#!/bin/bash
#
# Builds Biscuit from source and installs it to /Applications.
#
#   Scripts/install.sh [--prefix /Applications] [--vendor-wimlib]
#
# Why install from source: macOS applies the `com.apple.quarantine` attribute to
# files a *browser* downloaded, and Gatekeeper then refuses to launch anything
# that is not notarised. A bundle compiled on this machine never gets that
# attribute, so it launches normally — no certificate, no warning dialog, no
# right-click dance.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

PREFIX="/Applications"
VENDOR_FLAG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)        PREFIX="$2"; shift 2 ;;
    --vendor-wimlib) VENDOR_FLAG="--vendor-wimlib"; shift ;;
    -h|--help)       sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

[ "$(uname -s)" = "Darwin" ] || die "Biscuit läuft nur auf macOS."

MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MAJOR" -ge 14 ] || die "macOS 14 oder neuer erforderlich (gefunden: $(sw_vers -productVersion))."

command -v swift >/dev/null 2>&1 || die "Swift fehlt. Installiere die Command Line Tools: xcode-select --install"

if ! command -v wimlib-imagex >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/wimlib-imagex ]; then
  warn "wimlib ist nicht installiert."
  warn "Ohne wimlib lassen sich Windows-ISOs mit einer install.wim über 4 GB nicht verarbeiten."
  warn "Abhilfe: brew install wimlib"
fi

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

log "Baue Biscuit"
# shellcheck disable=SC2086
"$ROOT/Scripts/bundle.sh" --release $VENDOR_FLAG

SOURCE="$ROOT/dist/Biscuit.app"
[ -d "$SOURCE" ] || die "Build hat kein Bundle erzeugt."

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

TARGET="$PREFIX/Biscuit.app"

if [ -d "$TARGET" ]; then
  log "Beende eine laufende Instanz"
  osascript -e 'tell application "Biscuit" to quit' 2>/dev/null || true
  pkill -f "$TARGET/Contents/MacOS/Biscuit" 2>/dev/null || true
  sleep 1
fi

NEEDS_SUDO="no"
if [ ! -w "$PREFIX" ]; then NEEDS_SUDO="yes"; fi
if [ -d "$TARGET" ] && [ ! -w "$TARGET" ]; then NEEDS_SUDO="yes"; fi

if [ "$NEEDS_SUDO" = "yes" ]; then
  log "$PREFIX erfordert erhöhte Rechte — sudo wird abgefragt"
  sudo rm -rf "$TARGET"
  sudo ditto "$SOURCE" "$TARGET"
  # root:wheel with no write bit for group or other: a non-admin user must not
  # be able to replace the helper that later runs as root.
  sudo chown -R root:wheel "$TARGET"
  sudo chmod -R go-w "$TARGET"
  sudo chmod 755 "$TARGET/Contents/MacOS/biscuit-helper"
else
  rm -rf "$TARGET"
  ditto "$SOURCE" "$TARGET"
  chmod -R go-w "$TARGET"
fi

# Locally built bundles carry no quarantine flag; clearing it is belt and braces
# for the case where the repository itself was downloaded as a zip.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

codesign --verify --deep --strict "$TARGET" || die "Installierte App verifiziert nicht."

if xattr -p com.apple.quarantine "$TARGET" >/dev/null 2>&1; then
  warn "Das Quarantäne-Attribut ist noch gesetzt. Entferne es mit:"
  warn "  xattr -dr com.apple.quarantine '$TARGET'"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TARGET/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist")"

cat <<EOF

$(log "Installiert: $TARGET")
    Version $VERSION ($BUILD)

Starten:
    open "$TARGET"

Deinstallieren:
    rm -rf "$TARGET"
    rm -rf ~/Library/Application\\ Support/Biscuit

Biscuit installiert keinen dauerhaften Hintergrunddienst. Administrator-Rechte
werden einmal pro Sitzung abgefragt und nur so lange gehalten, wie ein Vorgang
läuft.
EOF
