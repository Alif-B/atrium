# Sourced by the other scripts. Works around a broken Command Line Tools install:
# a stale 2024 PackageDescription .private.swiftinterface shadows the correct one, so any Package.swift
# fails to link. We keep a patched copy inside the project and point SwiftPM at it (the system folder is root-owned).
ROOT="$(cd "$(dirname "${(%):-%x}")/.." && pwd)"
FIX="$ROOT/.toolchain-fix"
SRC=/Library/Developer/CommandLineTools/usr/lib/swift/pm
if [[ ! -d "$FIX/ManifestAPI" ]]; then
  mkdir -p "$FIX"
  cp -R "$SRC/ManifestAPI" "$SRC/PluginAPI" "$FIX/"
  chmod -R u+w "$FIX"
  rm -f "$FIX"/ManifestAPI/PackageDescription.swiftmodule/*.private.swiftinterface
fi
export SWIFTPM_CUSTOM_LIBS_DIR="$FIX"

# The default SDK here is macOS 27, whose SwiftUI needs the SwiftUIMacros plugin (ships with Xcode only, absent from the
# Command Line Tools), so `@State` fails to compile. Pin the macOS 26 SDK, which matches the OS Atrium runs on.
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
