#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT="${ROOT_DIR}/.build/headless/TarmacHeadless"

mkdir -p "$(dirname "$OUTPUT")"
cd "$ROOT_DIR"

xcrun swiftc \
  -DDEBUG \
  -parse-as-library \
  -module-name Tarmac \
  $(rg --files Sources -g '*.swift' | rg -v '^Sources/App/TarmacApp.swift$') \
  script/headless_tarmac.swift \
  -o "$OUTPUT" \
  -framework SwiftUI \
  -framework AppKit \
  -framework Virtualization \
  -framework Security

codesign \
  --force \
  --sign - \
  --entitlements Tarmac.entitlements \
  "$OUTPUT"

echo "$OUTPUT"
