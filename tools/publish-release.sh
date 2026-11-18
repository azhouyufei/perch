#!/bin/bash
# Publish the prepared packages using the current terminal's gh authentication.
set -euo pipefail
cd "$(dirname "$0")/.."
version=2.17.8
tag="v$version"
repo=azhouyufei/perch
assets="macos/build/release-$version/assets"
notes="docs/releases/$tag.md"
command -v gh >/dev/null
test -z "$(git status --porcelain)" || { echo 'Commit pending changes before publishing.' >&2; exit 1; }
test "$(git branch --show-current)" = main
test -f "$notes"
for file in "Perch-$version-macOS-arm64-personal.zip" "Perch-$version-Windows.zip" SHA256SUMS.txt; do
    test -s "$assets/$file" || { echo "Missing release asset: $file" >&2; exit 1; }
done
(cd "$assets" && shasum -a 256 -c SHA256SUMS.txt)
# Fail before any mutation when this shell cannot access the authenticated account.
gh api user --jq .login
head=$(git rev-parse HEAD)
if git rev-parse "$tag" >/dev/null 2>&1; then
    test "$(git rev-parse "$tag^{commit}")" = "$head" || { echo "$tag points to a different commit." >&2; exit 1; }
else
    git tag -a "$tag" -m "Perch $version"
fi
GIT_TERMINAL_PROMPT=0 git -c credential.helper= \
    -c 'credential.https://github.com.helper=!gh auth git-credential' \
    push origin main "refs/tags/$tag"
if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    test "$(gh release view "$tag" --repo "$repo" --json isDraft --jq .isDraft)" = true || {
        echo 'Release is already published; leaving its assets unchanged.'
        gh release view "$tag" --repo "$repo" --json url --jq .url
        exit 0
    }
else
    gh release create "$tag" --repo "$repo" --verify-tag --draft --title "Perch $version" --notes-file "$notes"
fi
gh release upload "$tag" "$assets/Perch-$version-macOS-arm64-personal.zip" "$assets/Perch-$version-Windows.zip" "$assets/SHA256SUMS.txt" --repo "$repo" --clobber
gh release edit "$tag" --repo "$repo" --notes-file "$notes" --draft=false --latest
gh release view "$tag" --repo "$repo" --json url --jq .url
