#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
out="$PWD/docs/screenshots"
mkdir -p "$out"
stage=$(mktemp -d "${TMPDIR:-/tmp}/perch-screens.XXXXXX")
app="$stage/Perch Preview.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp macos/Resources/Info.plist "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set CFBundleIdentifier org.perch.docs.screenshots' "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add ScreenshotDirectory string $out" "$app/Contents/Info.plist"
cp -R macos/Resources/*.lproj macos/Resources/*.icns macos/Island/ui "$app/Contents/Resources/"
cp tools/screenshots/macos/island-fixtures.json "$app/Contents/Resources/"
(cd macos && bash Scripts/build-island.sh "$stage/island")
sources=()
for file in macos/Sources/*.swift; do [[ "$file" == */main.swift ]] || sources+=("$file"); done
for unit in Telemetry Sensors Energy; do xcrun clang -O2 -mmacosx-version-min=13.0 -c "macos/Sources/$unit.c" -o "$stage/$unit.o"; done
xcrun swiftc -D PERCH_SCREENSHOTS -target "$(uname -m)-apple-macos13.0" -swift-version 5 -module-cache-path "${TMPDIR:-/tmp}/scopebar-modules" -import-objc-header macos/Sources/Telemetry.h "${sources[@]}" tools/screenshots/macos/main.swift "$stage"/*.o -I "$stage/island" -L "$stage/island" -lPerchIsland -lPerchCore -lIOReport -framework IOKit -framework Carbon -o "$app/Contents/MacOS/Perch"
codesign --force --sign - "$app"
if [[ "${1:-}" == "--build-only" ]]; then echo "$app"; exit 0; fi
trap 'rm -rf "$stage"' EXIT
open -n -W "$app" --args -AppleLanguages '(en)' -AppleLocale en_US
for theme in dark light; do
  for scene in "" dashboard- annotation- clipboard- note- panel- network- menu- island- conversation- character- setup-; do
    [[ "$out/macos-$scene$theme.png" -nt "$app/Contents/MacOS/Perch" ]]
  done
done
[[ "$out/macos-status.png" -nt "$app/Contents/MacOS/Perch" ]]
