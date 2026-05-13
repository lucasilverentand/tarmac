#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/.build/vm-smoke"
BIN="$BUILD_DIR/TarmacVMSmoke"

mkdir -p "$BUILD_DIR"

xcrun swiftc \
  -parse-as-library \
  -framework Virtualization \
  "$ROOT_DIR/script/vm_smoke.swift" \
  -o "$BIN"

codesign --force --sign - --timestamp=none --entitlements "$ROOT_DIR/Tarmac.entitlements" "$BIN" >/dev/null

args=("$@")
needs_install=false
no_boot=false

for arg in "${args[@]}"; do
  case "$arg" in
    --install|--ipsw|--download-latest)
      needs_install=true
      ;;
    --no-boot)
      no_boot=true
      ;;
  esac
done

if [[ "$needs_install" == true && "$no_boot" == false ]]; then
  "$BIN" "${args[@]}" --no-boot

  boot_args=()
  index=0
  while [[ $index -lt ${#args[@]} ]]; do
    arg="${args[$index]}"
    case "$arg" in
      --install|--download-latest|--no-boot)
        ;;
      --ipsw|--disk-size-gb)
        index=$((index + 1))
        ;;
      *)
        boot_args+=("$arg")
        ;;
    esac
    index=$((index + 1))
  done

  exec "$BIN" "${boot_args[@]}"
fi

exec "$BIN" "${args[@]}"
