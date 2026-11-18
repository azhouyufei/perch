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
if [[ -z "$identity" && -s build/signing-identity ]]; then identity=$(cat build/signing-identity); fi
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
if [[ -z "$identity" ]]; then
  if [[ "${ALLOW_ADHOC_SIGNING:-0}" == 1 ]]; then identity=-
  else
    echo "No accessible code-signing certificate. Use SIGNING_IDENTITY with your Xcode Apple Development certificate. Ad-hoc fallback is disabled." >&2
    exit 1
  fi
fi
if [[ "$identity" == "-" && "${ALLOW_ADHOC_SIGNING:-0}" != 1 ]]; then
  echo "Ad-hoc signing is only allowed for explicit test builds (ALLOW_ADHOC_SIGNING=1)." >&2
  exit 1
fi
fingerprint=$(
  { shasum -a 256 ../agent/{main,config,lock_unix}.go ../agent/go.mod ../assets/agent-avatar/* Sources/* Resources/*.plist Resources/*.icns Resources/*.lproj/*.strings Scripts/build*.sh Island/{Core,Native}/*.swift Island/LICENSE Island/ui/*.{js,css,html} Island/ui/dist/ui.css Island/ui/dist/fonts/* Island/blob-avatar.LICENSE
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

mkdir -p "$app/Contents/Helpers"
goarch=$arch
[[ "$arch" != x86_64 ]] || goarch=amd64
(cd ../agent && CGO_ENABLED=0 GOOS=darwin GOARCH="$goarch" go build -trimpath -ldflags="-s -w" -o "../macos/$app/Contents/Helpers/PerchAgent" .)
codesign --force --sign "$identity" "$app/Contents/Helpers/PerchAgent"
cp -R ../assets/agent-avatar "$app/Contents/Resources/"
bash Scripts/build-island.sh "$stage/island"
cp -R Island/ui "$app/Contents/Resources/"
cp Island/LICENSE "$app/Contents/Resources/PerchIsland-LICENSE"
cp Island/blob-avatar.LICENSE "$app/Contents/Resources/"
objects=()
for unit in Telemetry Sensors Energy; do
  xcrun clang -O2 -mmacosx-version-min=13.0 -c "Sources/$unit.c" -o "$stage/$unit.o"
  objects+=("$stage/$unit.o")
done
xcrun swiftc -O -swift-version 5 -target "$arch-apple-macos13.0" -module-cache-path "$cache" \
  -import-objc-header Sources/Telemetry.h Sources/*.swift "${objects[@]}" \
  -I "$stage/island" -L "$stage/island" -lPerchIsland -lPerchCore -lIOReport -framework IOKit -framework Carbon -o "$app/Contents/MacOS/Perch"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp -R Resources/*.lproj "$app/Contents/Resources/"
cp Resources/Perch.icns "$app/Contents/Resources/"
codesign --force --sign "$identity" "$app"
codesign --verify --strict "$app"
if [[ "$identity" != "-" ]]; then
  details=$(codesign -dv --verbose=4 "$app" 2>&1)
  if ! echo "$details" | grep -q '^Authority=Apple Development:\|^Authority=Developer ID Application:'; then
    echo "Expected an Apple Development or Developer ID Application signature." >&2; exit 1
  fi
fi
if [[ -e "$target" ]]; then mv "$target" "$stage/previous.app"; fi
if ! mv "$app" "$target"; then
  if [[ -e "$stage/previous.app" ]]; then mv "$stage/previous.app" "$target"; fi
  exit 1
fi
echo "$fingerprint" > build/glint-inputs
if [[ "$identity" != "-" ]]; then printf '%s\n' "$identity" > build/signing-identity; fi
if [[ "$identity" == "-" ]]; then
  echo "Local ad-hoc build. For stable permissions across code updates, set SIGNING_IDENTITY to a development or distribution certificate."
fi
