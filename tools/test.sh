#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

ARGS=()
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins"
MACROS="$(find "$PLUGINS" -name 'libTestingMacros.dylib' 2>/dev/null | head -1 || true)"
if [[ -n "$MACROS" && "$(dirname "$MACROS")" != "$PLUGINS" ]]; then
    ARGS+=(-Xswiftc -plugin-path -Xswiftc "$(dirname "$MACROS")")
fi
swift test ${ARGS[@]+"${ARGS[@]}"} "$@"
