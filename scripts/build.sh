#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Atrium"     # swiftbuild doesn't use .build/release
APP=build/Atrium.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Atrium"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
if security find-identity -p codesigning | grep -q "Atrium Local Signing"; then   # no -v: self-signed certs are "untrusted" but usable
  codesign --force --sign "Atrium Local Signing" "$APP"
else
  print -P "%F{yellow}⚠ Ad-hoc signing: Accessibility permission will reset on every build. See scripts/SIGNING.md%f"
  codesign --force --sign - "$APP"
fi
mkdir -p ~/Applications
rsync -a --delete "$APP/" ~/Applications/Atrium.app/
echo "Installed ~/Applications/Atrium.app"
