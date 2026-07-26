#!/bin/bash
set -euo pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

RUNNER_USER="${TARMAC_RUNNER_USER:-tarmac}"
RUNNER_PASSWORD="${TARMAC_RUNNER_PASSWORD:-}"
CONFIGURE_AUTO_LOGIN=1

usage() {
    cat <<'EOF'
Usage: sudo ./install-tarmac-runner-bootstrap.sh [options]

Options:
  --runner-user <name>  Guest account used by the runner (default: tarmac).
  --skip-auto-login     Install only the headless runner bootstrap.
  -h, --help            Show this help.

The default setup creates the standard runner account when needed, enables
automatic login, disables screen locking and sleep, and verifies the result.
Set TARMAC_RUNNER_PASSWORD for non-interactive installation.
EOF
}

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --runner-user)
            if [[ "$#" -lt 2 ]]; then
                echo "--runner-user requires a value." >&2
                exit 2
            fi
            RUNNER_USER="$2"
            shift 2
            ;;
        --skip-auto-login)
            CONFIGURE_AUTO_LOGIN=0
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$(id -u)" != "0" ]]; then
    echo "Run this installer as root." >&2
    exit 1
fi

# A failed host-side provisioning attempt may have installed this narrowly
# scoped one-command handoff. It must never survive bootstrap installation.
/bin/rm -f /etc/sudoers.d/tarmac-provisioning-bootstrap

if [[ ! "${RUNNER_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "Invalid runner user name: ${RUNNER_USER}" >&2
    exit 2
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

read_runner_password() {
    if [[ -n "${RUNNER_PASSWORD}" ]]; then
        return
    fi
    if [[ ! -t 0 ]]; then
        echo "TARMAC_RUNNER_PASSWORD is required for non-interactive automatic-login setup." >&2
        exit 3
    fi

    local confirmation
    printf 'Password for the %s guest account: ' "${RUNNER_USER}"
    IFS= read -r -s RUNNER_PASSWORD
    printf '\nConfirm password: '
    IFS= read -r -s confirmation
    printf '\n'

    if [[ -z "${RUNNER_PASSWORD}" ]]; then
        echo "The runner password cannot be empty." >&2
        exit 3
    fi
    if [[ "${RUNNER_PASSWORD}" != "${confirmation}" ]]; then
        echo "Passwords did not match." >&2
        exit 3
    fi
}

ensure_runner_user() {
    if /usr/bin/id -u "${RUNNER_USER}" >/dev/null 2>&1; then
        return
    fi

    echo "Creating standard guest account ${RUNNER_USER}."
    /usr/sbin/sysadminctl \
        -addUser "${RUNNER_USER}" \
        -fullName "Tarmac Runner" \
        -home "/Users/${RUNNER_USER}" \
        -shell /bin/bash \
        -password "${RUNNER_PASSWORD}"
}

configure_interactive_session() {
    read_runner_password
    ensure_runner_user

    if ! /usr/bin/dscl . -authonly "${RUNNER_USER}" "${RUNNER_PASSWORD}" >/dev/null 2>&1; then
        echo "The supplied password does not authenticate ${RUNNER_USER}." >&2
        exit 4
    fi

    if /usr/bin/fdesetup status | /usr/bin/grep -q 'FileVault is On'; then
        echo "Automatic login is unavailable while FileVault is enabled in the runner image." >&2
        echo "Disable FileVault in this disposable guest image, then rerun the installer." >&2
        exit 5
    fi

    /usr/sbin/sysadminctl \
        -autologin set \
        -userName "${RUNNER_USER}" \
        -password "${RUNNER_PASSWORD}"

    local configured_user
    configured_user="$(/usr/bin/defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser 2>/dev/null || true)"
    if [[ "${configured_user}" != "${RUNNER_USER}" || ! -f /etc/kcpassword ]]; then
        echo "macOS did not persist automatic login for ${RUNNER_USER}." >&2
        exit 6
    fi

    local runner_uid runner_gid runner_home preferences
    runner_uid="$(/usr/bin/id -u "${RUNNER_USER}")"
    runner_gid="$(/usr/bin/id -g "${RUNNER_USER}")"
    runner_home="$(/usr/bin/dscl . -read "/Users/${RUNNER_USER}" NFSHomeDirectory | /usr/bin/awk '{print $2}')"
    preferences="${runner_home}/Library/Preferences/com.apple.screensaver"

    /bin/mkdir -p "${runner_home}/Library/Preferences"
    /usr/bin/defaults write "${preferences}" idleTime -int 0
    /usr/bin/defaults write "${preferences}" askForPassword -int 0
    /usr/bin/defaults write "${preferences}" askForPasswordDelay -int 2147483647
    /usr/sbin/chown -R "${runner_uid}:${runner_gid}" "${runner_home}/Library"

    /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0

    unset RUNNER_PASSWORD TARMAC_RUNNER_PASSWORD
    echo "Configured ${RUNNER_USER} for automatic desktop login with screen lock and sleep disabled."
}

if [[ "${CONFIGURE_AUTO_LOGIN}" == "1" ]]; then
    configure_interactive_session
fi

echo "Installed Tarmac guest bootstrap."
echo "It will run automatically on the next boot when the host provides the shared VirtioFS tag."
if [[ "${CONFIGURE_AUTO_LOGIN}" == "1" ]]; then
    echo "Reboot the base image once and confirm the ${RUNNER_USER} desktop appears without a login prompt."
else
    echo "Automatic desktop login was skipped; Tarmac verification will require a manual ${RUNNER_USER} login."
fi
