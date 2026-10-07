#!/bin/bash
#
# Copies wimlib-imagex and its dylib into an app bundle and rewrites the install
# names so the binary resolves its library from inside the bundle.
#
#   Scripts/vendor-wimlib.sh <path-to-Biscuit.app>
#
# Licensing note: wimlib-imagex is GPL-3.0-or-later and the wimlib library is
# LGPL-3.0-or-later. Biscuit is GPL-3.0-or-later for exactly this reason, so
# redistributing both inside the bundle is permitted. The corresponding source
# must be made available — see THIRD-PARTY.md, which the release workflow ships
# alongside the archive.
#
set -euo pipefail

APP="${1:-}"
[ -n "$APP" ] || { echo "usage: vendor-wimlib.sh <Biscuit.app>" >&2; exit 64; }
[ -d "$APP/Contents/MacOS" ] || { echo "not an app bundle: $APP" >&2; exit 64; }

log() { printf '    %s\n' "$*"; }
die() { printf '    error: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Locate the source binary
# ---------------------------------------------------------------------------

IMAGEX=""
for candidate in \
  /opt/homebrew/bin/wimlib-imagex \
  /usr/local/bin/wimlib-imagex \
  /opt/local/bin/wimlib-imagex
do
  if [ -x "$candidate" ]; then IMAGEX="$candidate"; break; fi
done

[ -n "$IMAGEX" ] || die "wimlib-imagex nicht gefunden. Installiere es mit: brew install wimlib"

# Resolve Homebrew's symlink to the real Cellar path so otool sees the binary.
IMAGEX="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$IMAGEX")"
log "Quelle: $IMAGEX"

FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"

install -m 0755 "$IMAGEX" "$APP/Contents/MacOS/wimlib-imagex"
TARGET="$APP/Contents/MacOS/wimlib-imagex"

# ---------------------------------------------------------------------------
# Copy non-system dependencies and rewrite their install names
#
# Done iteratively because libwim itself links against libiconv, libcrypto and
# friends from Homebrew; a single pass would leave the second level dangling.
# ---------------------------------------------------------------------------

is_system_lib() {
  case "$1" in
    /usr/lib/*|/System/*|@rpath/*|@loader_path/*|@executable_path/*) return 0 ;;
    *) return 1 ;;
  esac
}

declare -a QUEUE=("$TARGET")
declare -a COPIED=()

while [ ${#QUEUE[@]} -gt 0 ]; do
  CURRENT="${QUEUE[0]}"
  QUEUE=("${QUEUE[@]:1}")

  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    is_system_lib "$dep" && continue

    REAL="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$dep" 2>/dev/null || echo "")"
    [ -n "$REAL" ] && [ -f "$REAL" ] || { log "überspringe nicht auflösbare Abhängigkeit: $dep"; continue; }

    BASE="$(basename "$REAL")"
    DEST="$FRAMEWORKS/$BASE"

    if [ ! -f "$DEST" ]; then
      install -m 0644 "$REAL" "$DEST"
      chmod u+w "$DEST"
      install_name_tool -id "@rpath/$BASE" "$DEST" 2>/dev/null || true
      COPIED+=("$BASE")
      QUEUE+=("$DEST")
      log "eingebunden: $BASE"
    fi

    install_name_tool -change "$dep" "@rpath/$BASE" "$CURRENT" 2>/dev/null || true
  done < <(otool -L "$CURRENT" | tail -n +2 | awk '{print $1}')
done

# The executable lives in Contents/MacOS, the libraries in Contents/Frameworks.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$TARGET" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

REMAINING="$(otool -L "$TARGET" | tail -n +2 | awk '{print $1}' | grep -E '^/(opt|usr/local)' || true)"
if [ -n "$REMAINING" ]; then
  die "Es verbleiben Verweise auf Pfade außerhalb des Bundles:
$REMAINING"
fi

# Strip quarantine and any extended attributes that would break signing.
xattr -cr "$TARGET" "$FRAMEWORKS" 2>/dev/null || true

# Re-sign before the smoke test. `install_name_tool` rewrites the Mach-O load
# commands, which invalidates the existing signature — and macOS then kills the
# process with SIGKILL on launch rather than reporting an error. bundle.sh signs
# everything again afterwards; this ad-hoc pass exists purely so the check below
# can actually run.
codesign --force --sign - "$FRAMEWORKS"/*.dylib 2>/dev/null || true
codesign --force --sign - "$TARGET" 2>/dev/null || true

log "wimlib eingebunden (${#COPIED[@]} Bibliotheken)"
if VERSION_LINE="$("$TARGET" --version 2>&1 | head -1)"; then
  log "$VERSION_LINE"
else
  die "Das eingebettete wimlib-imagex lässt sich nicht ausführen."
fi
