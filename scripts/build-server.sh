#!/bin/zsh
# Builds quota-server as a universal binary that runs on macOS 12.3 or later (Intel and Apple silicon).
# SwiftPM builds the package for macOS 14 (the menu bar app needs it), so the server is compiled with swiftc.
# The runtime compatibility libraries are skipped: current toolchains ship them for arm64 only, and macOS 12.3+
# already includes the runtime they back-deploy.
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"
OUT="$ROOT/build/server"
rm -rf "$OUT"
mkdir -p "$OUT"

for arch in x86_64 arm64; do
  work="$OUT/$arch"
  mkdir -p "$work"
  swiftc -target "$arch-apple-macos12.3" -swift-version 5 -O -runtime-compatibility-version none -parse-as-library \
    -emit-library -static -emit-module -module-name QuotaCore \
    -emit-module-path "$work/QuotaCore.swiftmodule" -o "$work/libQuotaCore.a" \
    Sources/QuotaCore/*.swift
  swiftc -target "$arch-apple-macos12.3" -swift-version 5 -O -runtime-compatibility-version none \
    -module-name QuotaServer -I "$work" -L "$work" -lQuotaCore \
    -o "$work/quota-server" Sources/QuotaServer/*.swift
done

lipo -create "$OUT/x86_64/quota-server" "$OUT/arm64/quota-server" -output "$OUT/quota-server"
codesign --force --sign - "$OUT/quota-server"
echo "Built $OUT/quota-server"
