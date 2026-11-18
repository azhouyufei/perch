#!/bin/bash
set -euo pipefail
out=$1
target="$(uname -m)-apple-macos13.0"
flags=(-O -whole-module-optimization -swift-version 5 -target "$target" -module-cache-path "${TMPDIR:-/tmp}/scopebar-modules" -parse-as-library -emit-module -emit-library -static)
mkdir -p "$out"
for entry in "PerchCore Core" "PerchIsland Native"; do
  read -r module dir <<< "$entry"
  xcrun swiftc "${flags[@]}" -module-name "$module" -I "$out" Island/"$dir"/*.swift \
    -emit-module-path "$out/$module.swiftmodule" -o "$out/lib$module.a"
done
