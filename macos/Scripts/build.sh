#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
cache="${TMPDIR:-/tmp}/scopebar-modules"
arch=$(uname -m)
mkdir -p build "$cache"
stage=$(mktemp -d build/.glint-build.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Perch.app"
target=build/Perch.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

# Keep using the same certificate on updates. An explicit identity takes precedence.
identity=${SIGNING_IDENTITY:-}
existing=""
previous="$target"
if [[ ! -d "$previous" ]]; then previous=build/DeskToys.app; fi
if [[ ! -d "$previous" ]]; then previous=build/效率工具箱.app; fi
if [[ ! -d "$previous" ]]; then previous=build/ScopeBar.app; fi
if [[ -d "$previous" ]]; then
  existing=$(codesign -dv --verbose=2 "$previous" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)
fi
if [[ -z "$identity" ]]; then
  identity=$existing
  if [[ -z "$identity" ]]; then
    identity=$(security find-identity -v -p codesigning 2>/dev/null | awk '/"(Apple Development:|Developer ID Application:)/ && !id {id=$2} END{print id}' || true)
  fi
fi
identity=${identity:--}
fingerprint=$(
  { shasum -a 256 Sources/* Resources/*.plist Resources/*.icns Resources/*.lproj/*.strings Scripts/build.sh
    xcrun swiftc --version
    xcrun --show-sdk-version
    echo "$arch $identity"
  } | shasum -a 256 | cut -d' ' -f1
)
if [[ -f build/glint-inputs && $(cat build/glint-inputs) == "$fingerprint" ]] &&
   codesign --verify --strict "$target" 2>/dev/null; then
  echo "Perch is up to date."
  exit 0
fi

objects=()
for unit in Telemetry Sensors Energy; do
  xcrun clang -O2 -mmacosx-version-min=13.0 -c "Sources/$unit.c" -o "$stage/$unit.o"
  objects+=("$stage/$unit.o")
done
xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -module-cache-path "$cache" \
  -import-objc-header Sources/Telemetry.h Sources/*.swift "${objects[@]}" \
  -lIOReport -framework IOKit -framework Carbon -o "$app/Contents/MacOS/Perch"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp Resources/Perch.icns "$app/Contents/Resources/"
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
if [[ -e "$target" ]]; then mv "$target" "$stage/previous.app"; fi
if ! mv "$app" "$target"; then
  if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$target"; fi
  exit 1
fi
echo "$fingerprint" > build/glint-inputs
if [[ "$identity" == "-" ]]; then
  echo "Local ad-hoc build. For stable permissions across code updates, set SIGNING_IDENTITY to a development or distribution certificate."
fi
