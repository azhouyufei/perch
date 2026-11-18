#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cache="${TMPDIR:-/tmp}/scopebar-modules"
xcrun clang -O2 -mmacosx-version-min=13.0 -c Sources/Telemetry.c -o "$tmp/Telemetry.o"
for unit in Sensors Energy; do xcrun clang -O2 -mmacosx-version-min=13.0 -c "Sources/$unit.c" -o "$tmp/$unit.o"; done
bash Scripts/build-island.sh "$tmp/island"
xcrun swiftc -swift-version 5 -module-cache-path "$cache" -I "$tmp/island" -L "$tmp/island" -lPerchCore \
  Island/Native/{Preferences,HookServer}.swift Tests/{IslandHooks,CodexThreads}.swift -o "$tmp/island-hooks"
PERCH_HOME="$tmp/user" CLAUDE_CONFIG_DIR="$tmp/claude config" CODEX_HOME="$tmp/codex" "$tmp/island-hooks"
xcrun swiftc -I "$tmp/island" -L "$tmp/island" -lPerchIsland -lPerchCore -target "$(uname -m)-apple-macos13.0" -swift-version 5 -module-cache-path "$cache" -import-objc-header Sources/Telemetry.h Sources/{AgentAlerts,Localization,StartupPreferences,AwakeSession,CodexQuota,UsageMetadata,Todos,ClipboardHistory,ClipboardViews,AnnotationOptions,Theme,Monitor,Processes,Captures,Editor,Selection,SystemCapturePicker,HotKeys,NetworkInfo,Usage,ProcessTables,InstrumentPanel,Application,Workspace,MonitorViews,Charts,UsageViews,UsageCalendar}.swift Tests/main.swift "$tmp/Telemetry.o" "$tmp/Sensors.o" "$tmp/Energy.o" -lIOReport -framework IOKit -o "$tmp/check"
"$tmp/check"
