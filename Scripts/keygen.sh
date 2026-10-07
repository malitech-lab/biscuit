#!/bin/bash
#
# Generates the Ed25519 release signing key.
#
#   Scripts/keygen.sh [output-directory]
#
# Produces:
#   biscuit-release.key   private key (PEM) — NEVER commit, NEVER publish
#   biscuit-release.pub   public key, base64 raw 32 bytes — goes in the build
#
# The public half is compiled into every build via BISCUIT_UPDATE_PUBKEY, and the
# updater refuses any archive that is not signed by the matching private half.
# That is what makes an unsigned, non-notarised app safe to auto-update: the
# trust anchor is this key, not Apple's.
#
# Store the private key in the repository's GitHub Actions secrets as
# BISCUIT_RELEASE_PRIVATE_KEY (the full PEM text) and nowhere else. Losing it means
# existing installations can no longer be updated; leaking it means an attacker
# can push an update to every installation.
#
set -euo pipefail

OUTPUT_DIR="${1:-secrets}"
mkdir -p "$OUTPUT_DIR"
chmod 700 "$OUTPUT_DIR"

PRIVATE="$OUTPUT_DIR/biscuit-release.key"
PUBLIC="$OUTPUT_DIR/biscuit-release.pub"

# macOS ships LibreSSL as /usr/bin/openssl, which cannot do Ed25519. Prefer a
# real OpenSSL from Homebrew and fail loudly rather than silently producing an
# unusable key.
OPENSSL=""
for candidate in \
  /opt/homebrew/opt/openssl@3/bin/openssl \
  /usr/local/opt/openssl@3/bin/openssl \
  /opt/homebrew/bin/openssl \
  /usr/local/bin/openssl \
  "$(command -v openssl || true)"
do
  [ -x "$candidate" ] || continue
  if "$candidate" genpkey -algorithm ED25519 -out /dev/null 2>/dev/null; then
    OPENSSL="$candidate"
    break
  fi
done

if [ -z "$OPENSSL" ]; then
  echo "error: keine OpenSSL-Version mit Ed25519-Unterstützung gefunden." >&2
  echo "       macOS liefert LibreSSL, das Ed25519 nicht kann." >&2
  echo "       Abhilfe: brew install openssl@3" >&2
  exit 1
fi

echo "==> OpenSSL: $OPENSSL ($("$OPENSSL" version))"

if [ -f "$PRIVATE" ]; then
  echo "error: $PRIVATE existiert bereits. Überschreiben würde alle bestehenden" >&2
  echo "       Installationen von Updates abschneiden. Lösche die Datei bewusst," >&2
  echo "       wenn das gewollt ist." >&2
  exit 1
fi

"$OPENSSL" genpkey -algorithm ED25519 -out "$PRIVATE"
chmod 600 "$PRIVATE"

# The DER SPKI encoding for Ed25519 is a fixed 12-byte header followed by the
# 32-byte raw key, so the tail is exactly what CryptoKit's
# Curve25519.Signing.PublicKey(rawRepresentation:) expects.
"$OPENSSL" pkey -in "$PRIVATE" -pubout -outform DER \
  | tail -c 32 \
  | base64 \
  | tr -d '\n' > "$PUBLIC"
printf '\n' >> "$PUBLIC"
chmod 644 "$PUBLIC"

PUBKEY="$(cat "$PUBLIC")"
BYTES="$(printf '%s' "$PUBKEY" | base64 -d | wc -c | tr -d ' ')"
if [ "$BYTES" != "32" ]; then
  echo "error: öffentlicher Schlüssel hat $BYTES statt 32 Bytes" >&2
  exit 1
fi

cat <<EOF

==> Schlüsselpaar erzeugt

  Privat:    $PRIVATE   (Modus 600 — niemals committen)
  Öffentlich: $PUBLIC

  Öffentlicher Schlüssel (base64, 32 Bytes):
    $PUBKEY

Nächste Schritte:

  1. Privaten Schlüssel als GitHub-Secret ablegen:
       gh secret set BISCUIT_RELEASE_PRIVATE_KEY < $PRIVATE

  2. Öffentlichen Schlüssel als Repository-Variable ablegen:
       gh variable set BISCUIT_UPDATE_PUBKEY --body "$PUBKEY"

  3. Lokal bauen mit eingebettetem Schlüssel:
       BISCUIT_UPDATE_PUBKEY="$PUBKEY" Scripts/bundle.sh --release

  4. $PRIVATE zusätzlich offline sichern (Passwort-Manager, verschlüsselter
     Datenträger). Ohne diesen Schlüssel sind keine weiteren Updates möglich.

EOF
