#!/bin/bash
# Re-sign the already-built app with an existing Xcode development identity.
# This does not create/export certificates or private keys, or modify keychain ACLs.
set -euo pipefail
cd "$(dirname "$0")/.."
target=build/Perch.app
[[ -d "$target" ]] || { echo "Build Perch.app first." >&2; exit 1; }
identity=${SIGNING_IDENTITY:-}
if [[ -z "$identity" && -s build/signing-identity ]]; then identity=$(cat build/signing-identity); fi
if [[ -z "$identity" ]]; then
  identities=$(security find-identity -v -p codesigning)
  count=$(printf '%s\n' "$identities" | awk '/"Apple Development:/ {n++} END {print n+0}')
  if [[ "$count" != 1 ]]; then
    echo "Found $count accessible Apple Development identities. In Xcode > Settings > Accounts > Manage Certificates, check that your certificate and private key are installed." >&2
    echo "If multiple certificates are installed, set SIGNING_IDENTITY to your personal certificate's SHA-1 from security find-identity -v -p codesigning." >&2
    exit 1
  fi
  identity=$(printf '%s\n' "$identities" | awk '/"Apple Development:/ {print $2}')
fi
[[ "$identity" != - ]] || { echo "A personal Apple Development certificate is required." >&2; exit 1; }
stage=$(mktemp -d build/.personal-sign.XXXXXX)
trap 'rm -rf "$stage"' EXIT
app="$stage/Perch.app"
ditto "$target" "$app"
codesign --force --sign "$identity" "$app/Contents/Helpers/PerchAgent"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
details=$(codesign -dv --verbose=4 "$app" 2>&1)
if ! printf '%s\n' "$details" | grep -q '^Authority=Apple Development:'; then
  echo "The selected identity is not an Xcode Apple Development identity. Original app preserved." >&2
  exit 1
fi
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
arch=$(lipo -archs "$app/Contents/MacOS/Perch" | tr ' ' '-')
archive="build/Perch-${version}-macOS-${arch}-personal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$stage/signed.zip"
mv "$target" "$stage/previous.app"
if ! mv "$app" "$target"; then mv "$stage/previous.app" "$target"; exit 1; fi
mv "$stage/signed.zip" "$archive"
printf '%s\n' "$identity" > build/signing-identity
printf '%s\n' "$details" | grep -E '^(Identifier|Authority|TeamIdentifier)='
echo "Signed with your personal development certificate: $PWD/$archive"
echo "Future local builds will reuse this identity. This development package is not a notarized Developer ID release."
