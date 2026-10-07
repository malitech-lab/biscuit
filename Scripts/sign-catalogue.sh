#!/bin/bash
#
# Signs the image catalogue with the project's Ed25519 release key.
#
#   Scripts/sign-catalogue.sh --catalogue dist/catalogue.json [--key PATH]
#
# The same key that signs app releases signs the catalogue, and for the same
# reason: the catalogue decides which URL a user downloads and which checksum
# that download is held to. An attacker who could substitute it could point
# every installation at an image of their choosing. It is exactly as
# security-critical as an app update and is protected identically.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

CATALOGUE=""
KEY="${BISCUIT_RELEASE_KEY_PATH:-$ROOT/secrets/biscuit-release.key}"

while [ $# -gt 0 ]; do
  case "$1" in
    --catalogue) CATALOGUE="$2"; shift 2 ;;
    --key)       KEY="$2"; shift 2 ;;
    -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 64 ;;
  esac
done

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$CATALOGUE" ] || die "--catalogue fehlt"
[ -f "$CATALOGUE" ] || die "Katalog nicht gefunden: $CATALOGUE"
[ -f "$KEY" ] || die "Signaturschlüssel nicht gefunden: $KEY"

# macOS ships LibreSSL as /usr/bin/openssl, which cannot do Ed25519. Failing
# loudly beats producing a signature that no client will accept.
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

OPENSSL="$(find_openssl)" || die "Keine OpenSSL-Version mit Ed25519. Abhilfe: brew install openssl@3"
log "OpenSSL: $OPENSSL"

# Structural check before signing. A signature over a malformed catalogue is a
# correctly signed way to break every client.
python3 - "$CATALOGUE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as handle:
    catalogue = json.load(handle)

required = {"formatVersion", "generatedAt", "entries"}
missing = required - catalogue.keys()
if missing:
    sys.exit(f"catalogue is missing {', '.join(sorted(missing))}")

def images(nodes):
    for node in nodes:
        if node.get("kind") == "image":
            yield node["image"]
        elif node.get("kind") == "category":
            yield from images(node["category"]["children"])

found = list(images(catalogue["entries"]))
if not found:
    sys.exit("catalogue contains no images")

seen = set()
for image in found:
    identifier = image.get("id")
    if not identifier or identifier in seen:
        sys.exit(f"duplicate or missing id: {identifier!r}")
    seen.add(identifier)
    if not image.get("url", "").startswith("https://"):
        sys.exit(f"{identifier}: url is not https")
    if not (image.get("downloadSHA256") or image.get("expandedSHA256")):
        sys.exit(f"{identifier}: no checksum — refusing to sign an unverifiable entry")

print(f"    {len(found)} entries, all https, all with a checksum")
PY

log "Signiere $CATALOGUE"
"$OPENSSL" pkeyutl -sign -inkey "$KEY" -rawin -in "$CATALOGUE" -out "$CATALOGUE.sig"

SIZE="$(stat -f%z "$CATALOGUE.sig" 2>/dev/null || stat -c%s "$CATALOGUE.sig")"
[ "$SIZE" = "64" ] || die "Signatur hat $SIZE statt 64 Bytes"

# Verify immediately with the public half, so a broken key never ships.
PUB="$(mktemp)"
trap 'rm -f "$PUB"' EXIT
"$OPENSSL" pkey -in "$KEY" -pubout -outform DER -out "$PUB"
"$OPENSSL" pkeyutl -verify -pubin -inkey "$PUB" -keyform DER \
  -rawin -in "$CATALOGUE" -sigfile "$CATALOGUE.sig" >/dev/null \
  || die "Eigene Signatur verifiziert nicht"

DERIVED="$("$OPENSSL" pkey -in "$KEY" -pubout -outform DER | tail -c 32 | base64 | tr -d '\n')"

log "Signatur erzeugt und verifiziert"
printf '    %s\n' "$CATALOGUE.sig"
printf '    Öffentlicher Schlüssel: %s\n' "$DERIVED"
printf '    Dieser Wert muss mit BISCUIT_UPDATE_PUBKEY im App-Build übereinstimmen.\n'
