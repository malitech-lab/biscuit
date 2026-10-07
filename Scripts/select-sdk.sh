#!/bin/bash
#
# Prints the SDK path that should be used as SDKROOT, or nothing if the default
# SDK is fine.
#
#   export SDKROOT="$(Scripts/select-sdk.sh)"
#
# Background: in macOS SDKs from 15.4 onward, SwiftUI's `@State`, `@Binding` and
# friends are attached macros implemented by a plugin called SwiftUIMacros. That
# plugin ships only with full Xcode. On a machine with just the Command Line
# Tools the plugin is absent, so every SwiftUI view fails to compile with
# "plugin for module 'SwiftUIMacros' not found".
#
# Building against the newest SDK that still declares those as plain property
# wrappers avoids a 10 GB Xcode download. The deployment target is unaffected —
# that comes from Package.swift.
#
# With Xcode installed this prints nothing and the default SDK is used.
#
set -euo pipefail

DEVELOPER_DIR="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"

# Xcode ships a Platforms directory and the macro plugin; the CLT do not.
if [ -d "$DEVELOPER_DIR/Platforms/MacOSX.platform" ]; then
  exit 0
fi
if [ -f "$DEVELOPER_DIR/usr/lib/swift/host/plugins/libSwiftUIMacros.dylib" ]; then
  exit 0
fi

BEST=""
for candidate in "$DEVELOPER_DIR"/SDKs/MacOSX*.sdk; do
  [ -d "$candidate" ] || continue
  # Skip the unversioned alias so the result names a concrete SDK.
  [ "$(basename "$candidate")" = "MacOSX.sdk" ] && continue

  interface="$candidate/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/arm64e-apple-macos.swiftinterface"
  if [ ! -f "$interface" ]; then
    interface="$candidate/System/Library/Frameworks/SwiftUICore.framework/Modules/SwiftUICore.swiftmodule/x86_64-apple-macos.swiftinterface"
  fi
  [ -f "$interface" ] || continue

  # A `macro State` declaration means this SDK needs the plugin.
  grep -q "macro State" "$interface" 2>/dev/null && continue

  if [ -z "$BEST" ]; then
    BEST="$candidate"
  else
    NEWER="$(printf '%s\n%s\n' "$BEST" "$candidate" | sort -V | tail -1)"
    BEST="$NEWER"
  fi
done

if [ -n "$BEST" ]; then
  printf '%s' "$BEST"
fi
