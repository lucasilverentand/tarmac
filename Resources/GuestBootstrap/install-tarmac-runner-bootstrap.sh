#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

if [[ "$(id -u)" != "0" ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SRC="${SCRIPT_DIR}/tarmac-runner-bootstrap.sh"
PLIST_SRC="${SCRIPT_DIR}/studio.seventwo.tarmac.runner-bootstrap.plist"

BOOTSTRAP_DEST="/usr/local/libexec/tarmac-runner-bootstrap"
PLIST_DEST="/Library/LaunchDaemons/studio.seventwo.tarmac.runner-bootstrap.plist"

if [[ ! -f "${BOOTSTRAP_SRC}" ]]; then
    echo "Missing ${BOOTSTRAP_SRC}" >&2
    exit 2
fi

if [[ ! -f "${PLIST_SRC}" ]]; then
    echo "Missing ${PLIST_SRC}" >&2
    exit 2
fi

/usr/bin/plutil -lint "${PLIST_SRC}" >/dev/null

/usr/bin/install -d -o root -g wheel -m 0755 /usr/local/libexec
/usr/bin/install -o root -g wheel -m 0755 "${BOOTSTRAP_SRC}" "${BOOTSTRAP_DEST}"
/usr/bin/install -o root -g wheel -m 0644 "${PLIST_SRC}" "${PLIST_DEST}"

echo "Installed Tarmac guest bootstrap."
echo "It will run automatically on the next boot when the host provides the shared VirtioFS tag."
