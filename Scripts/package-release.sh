#!/bin/bash
#
# Packages a built app into the release archive and signs it.
#
#   Scripts/package-release.sh --version X.Y.Z [--app PATH] [--output DIR]
#                              [--key PATH]
#
# Produces, in the output directory:
#   Biscuit-X.Y.Z.zip        the archive the updater downloads
#   Biscuit-X.Y.Z.zip.sig    detached raw Ed25519 signature (64 bytes)
#   Biscuit-X.Y.Z.zip.sha256 checksum, for Homebrew and manual verification
#
# The signature is what the in-app updater verifies. Without it, a release is
# unusable for automatic updates by design.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

VERSION=""
APP="$ROOT/dist/Biscuit.app"
OUTPUT_DIR="$ROOT/dist"
KEY="${BISCUIT_RELEASE_KEY_PATH:-$ROOT/secrets/biscuit-release.key}"

while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="$2"; shift 2 ;;
    --app)     APP="$2"; shift 2 ;;
    --output)  OUTPUT_DIR="$2"; shift 2 ;;
    --key)     KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$VERSION" ] || die "--version fehlt"
[ -d "$APP" ] || die "App nicht gefunden: $APP"
mkdir -p "$OUTPUT_DIR"

# ---------------------------------------------------------------------------
# Sanity-check the bundle before publishing it
# ---------------------------------------------------------------------------

BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
[ "$BUNDLE_VERSION" = "$VERSION" ] || \
  die "Versionskonflikt: Bundle meldet '$BUNDLE_VERSION', erwartet '$VERSION'"

[ -x "$APP/Contents/MacOS/Biscuit" ] || die "App-Binary fehlt"
[ -x "$APP/Contents/MacOS/biscuit-helper" ] || die "Helfer-Binary fehlt"

PUBKEY_IN_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :BiscuitUpdatePublicKey' "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
if [ -z "$PUBKEY_IN_BUNDLE" ]; then
  warn "Im Bundle ist kein Update-Schlüssel eingebettet — diese Version kann sich"
  warn "später nicht selbst aktualisieren. Setze BISCUIT_UPDATE_PUBKEY beim Bauen."
fi

# Das Update-Repository entscheidet, wo die ausgelieferte App nach neuen
# Versionen fragt. Bleibt der Platzhalter stehen, fragt sie bei einem fremden
# Repository — und akzeptiert von dort Archive, sofern deren Signatur zum
# eingebetteten Schlüssel passt. Ein Release damit auszuliefern ist kein
# Schönheitsfehler, deshalb bricht es hier ab und warnt nicht bloß.
REPO_IN_BUNDLE="$(/usr/libexec/PlistBuddy -c 'Print :BiscuitUpdateRepository' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo "")"
case "$REPO_IN_BUNDLE" in
  ""|"biscuit/biscuit"|"dein-konto/biscuit"|*"<owner>"*|*"OWNER"*)
    die "Update-Repository ist noch der Platzhalter ('$REPO_IN_BUNDLE').
  Abhilfe: BISCUIT_UPDATE_REPO=dein-konto/biscuit make app" ;;
esac
log "Update-Repository: $REPO_IN_BUNDLE"

codesign --verify --deep --strict "$APP" || die "Signaturprüfung fehlgeschlagen"

# ---------------------------------------------------------------------------
# Archive
#
# `ditto -c -k --sequesterRsrc --keepParent` is the only archiver that reliably
# round-trips a macOS bundle: symlinks, the executable bit and extended
# attributes all survive. A plain `zip` produces a bundle that will not launch.
# ---------------------------------------------------------------------------

ARCHIVE="$OUTPUT_DIR/Biscuit-$VERSION.zip"
log "Erzeuge $ARCHIVE"
rm -f "$ARCHIVE"

# Strip quarantine so the archive never carries it; the updater relies on the
# extracted bundle being clean.
xattr -cr "$APP" 2>/dev/null || true

ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"

ARCHIVE_SIZE="$(stat -f%z "$ARCHIVE")"
log "Archivgröße: $ARCHIVE_SIZE Bytes"

# ---------------------------------------------------------------------------
# Verify the archive actually restores to a working bundle
# ---------------------------------------------------------------------------

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
ditto -x -k "$ARCHIVE" "$VERIFY_DIR"
[ -x "$VERIFY_DIR/Biscuit.app/Contents/MacOS/Biscuit" ] || \
  die "Entpacktes Archiv enthält kein ausführbares App-Binary"
[ -x "$VERIFY_DIR/Biscuit.app/Contents/MacOS/biscuit-helper" ] || \
  die "Entpacktes Archiv enthält keinen ausführbaren Helfer"
codesign --verify --deep --strict "$VERIFY_DIR/Biscuit.app" || \
  die "Signatur überlebt das Archivieren nicht"
log "Archiv verifiziert: Bundle bleibt intakt und signiert"

# ---------------------------------------------------------------------------
# Checksum
# ---------------------------------------------------------------------------

SHA="$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$SHA" "$(basename "$ARCHIVE")" > "$ARCHIVE.sha256"
log "SHA-256: $SHA"

# ---------------------------------------------------------------------------
# Signature
# ---------------------------------------------------------------------------

find_openssl() {
  local candidate
  for candidate in \
    /opt/homebrew/opt/openssl@3/bin/openssl \
    /usr/local/opt/openssl@3/bin/openssl \
    /opt/homebrew/bin/openssl \
    /usr/local/bin/openssl \
    "$(command -v openssl || true)"
  do
    [ -x "$candidate" ] || continue
    if "$candidate" genpkey -algorithm ED25519 -out /dev/null 2>/dev/null; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

if [ ! -f "$KEY" ]; then
  warn "Signaturschlüssel nicht gefunden: $KEY"
  warn "Das Archiv wird UNSIGNIERT veröffentlicht und von der App nicht als"
  warn "Update akzeptiert. Erzeuge einen Schlüssel mit Scripts/keygen.sh."
  exit 0
fi

OPENSSL="$(find_openssl)" || \
  die "Keine OpenSSL-Version mit Ed25519. Abhilfe: brew install openssl@3"

log "Signiere mit $OPENSSL"
"$OPENSSL" pkeyutl -sign \
  -inkey "$KEY" \
  -rawin \
  -in "$ARCHIVE" \
  -out "$ARCHIVE.sig"

SIG_SIZE="$(stat -f%z "$ARCHIVE.sig")"
[ "$SIG_SIZE" = "64" ] || die "Signatur hat $SIG_SIZE statt 64 Bytes"

# Verify immediately with the public half, so a broken key never ships.
PUBTMP="$VERIFY_DIR/pub.der"
"$OPENSSL" pkey -in "$KEY" -pubout -outform DER -out "$PUBTMP"
"$OPENSSL" pkeyutl -verify \
  -pubin -inkey "$PUBTMP" -keyform DER \
  -rawin -in "$ARCHIVE" \
  -sigfile "$ARCHIVE.sig" >/dev/null || die "Eigene Signatur verifiziert nicht"

DERIVED_PUBKEY="$("$OPENSSL" pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')"
if [ -n "$PUBKEY_IN_BUNDLE" ] && [ "$DERIVED_PUBKEY" != "$PUBKEY_IN_BUNDLE" ]; then
  die "Der eingebettete Update-Schlüssel passt nicht zum Signaturschlüssel.
  Bundle:     $PUBKEY_IN_BUNDLE
  Signatur:   $DERIVED_PUBKEY
  Diese Version würde ihr eigenes Update ablehnen."
fi

log "Signatur erzeugt und verifiziert"
log ""
log "Release-Artefakte in $OUTPUT_DIR:"
# shellcheck disable=SC2012  # Anzeige für den Menschen: die Dateinamen stehen
# explizit da und werden nicht aus der Ausgabe geparst, worum es bei SC2012 geht.
ls -la "$ARCHIVE" "$ARCHIVE.sig" "$ARCHIVE.sha256" | sed 's/^/    /'
