#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORAGE_ROOT="${1:-/Volumes/DevDisk/Tarmac}"
IMAGE_PATH="$STORAGE_ROOT/BaseImage.img"
MOUNT_ROOT="/tmp/tarmac-base-image-mount"

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "Base image not found at $IMAGE_PATH" >&2
  exit 1
fi

rm -rf "$MOUNT_ROOT"
mkdir -p "$MOUNT_ROOT"

attach_output="$(
  hdiutil attach \
    -imagekey diskimage-class=CRawDiskImage \
    -owners off \
    -mountroot "$MOUNT_ROOT" \
    "$IMAGE_PATH"
)"

whole_disk="$(
  awk '/GUID_partition_scheme/ { sub("^/dev/", "", $1); print $1; exit }' <<<"$attach_output"
)"

cleanup() {
  if [[ -n "${whole_disk:-}" ]]; then
    hdiutil detach "/dev/$whole_disk" >/dev/null 2>&1 || true
  fi
  rm -rf "$MOUNT_ROOT"
}
trap cleanup EXIT

data_mount="$(
  mount | awk -v root="$MOUNT_ROOT" '$3 ~ root && $3 ~ /Data/ { print $3; exit }'
)"

if [[ -z "$data_mount" ]]; then
  data_mount="$(find "$MOUNT_ROOT" -maxdepth 2 -type d -name Data -print -quit)"
fi

if [[ -z "$data_mount" ]]; then
  echo "Could not find mounted Data volume under $MOUNT_ROOT" >&2
  exit 1
fi

mkdir -p "$data_mount/usr/local/libexec" "$data_mount/Library/LaunchDaemons"
mkdir -p "$data_mount/private/var/db"
cp "$ROOT_DIR/Resources/GuestBootstrap/tarmac-runner-bootstrap.sh" \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap"
cp "$ROOT_DIR/Resources/GuestBootstrap/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist"
touch "$data_mount/private/var/db/.AppleSetupDone"

chown root:wheel \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/private/var/db/.AppleSetupDone" 2>/dev/null || true
chmod 755 "$data_mount/usr/local/libexec/tarmac-runner-bootstrap"
chmod 644 "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist"
chmod 644 "$data_mount/private/var/db/.AppleSetupDone"
xattr -cr \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/private/var/db/.AppleSetupDone" 2>/dev/null || true

ls -lne@ \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/private/var/db/.AppleSetupDone"
