#!/bin/zsh
set -euo pipefail

cd "${0:A:h:h}"

# Command Line Tools ship the Swift Testing macro plugin outside the default search path.
PLUGINS="$(xcode-select -p)/usr/lib/swift/host/plugins/testing"
if [[ -d "$PLUGINS" ]]; then
  swift test -Xswiftc -plugin-path -Xswiftc "$PLUGINS" "$@"
else
  swift test "$@"
fi
