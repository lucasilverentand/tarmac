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

owner_user=""
user_directory="$data_mount/private/var/db/dslocal/nodes/Default/users"
if [[ -d "$user_directory" ]]; then
  while IFS= read -r user_plist; do
    user_name="$(/usr/libexec/PlistBuddy -c 'Print :name:0' "$user_plist" 2>/dev/null || true)"
    user_id="$(/usr/libexec/PlistBuddy -c 'Print :uid:0' "$user_plist" 2>/dev/null || true)"
    if [[ "$user_id" =~ ^[0-9]+$ ]] && (( user_id >= 500 )) && [[ -n "$user_name" && "$user_name" != _* ]]; then
      owner_user="$user_name"
      break
    fi
  done < <(find "$user_directory" -maxdepth 1 -type f -name '*.plist' -print | sort)
fi

if [[ -z "$owner_user" ]]; then
  echo "No local macOS owner account exists in the base image." >&2
  echo "Boot the image, complete Setup Assistant with the tarmac administrator account, then rerun this injector." >&2
  echo "The injector will not bypass Setup Assistant on an ownerless image." >&2
  exit 2
fi

echo "Found prepared guest account: $owner_user"

runner_password="${TARMAC_RUNNER_PASSWORD:-}"
if [[ -z "$runner_password" ]]; then
  runner_password="$(/usr/bin/openssl rand -hex 12)"
  echo "Generated a strong guest runner password for automatic login."
fi

mkdir -p "$data_mount/usr/local/libexec" "$data_mount/Library/LaunchDaemons"
mkdir -p "$data_mount/private/var/db"
cp "$ROOT_DIR/Resources/GuestBootstrap/tarmac-runner-bootstrap.sh" \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap"
cp "$ROOT_DIR/Resources/GuestBootstrap/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist"
printf '%s\n' "$runner_password" > "$data_mount/private/var/db/tarmac-runner-autologin-password"

chown root:wheel \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/private/var/db/tarmac-runner-autologin-password" 2>/dev/null || true
chmod 755 "$data_mount/usr/local/libexec/tarmac-runner-bootstrap"
chmod 644 "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist"
chmod 600 "$data_mount/private/var/db/tarmac-runner-autologin-password"
xattr -cr \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/private/var/db/tarmac-runner-autologin-password" 2>/dev/null || true

ls -lne@ \
  "$data_mount/usr/local/libexec/tarmac-runner-bootstrap" \
  "$data_mount/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist" \
  "$data_mount/private/var/db/tarmac-runner-autologin-password"

unset runner_password owner_user user_name user_id TARMAC_RUNNER_PASSWORD
