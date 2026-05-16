#!/bin/bash
set -u -o pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SHARED_TAG="shared"
SHARED_MOUNT="/Volumes/tarmac-shared"
CACHE_TAG="actions-cache"
CACHE_MOUNT="/Volumes/actions-cache"
LOCAL_LOG="/var/log/tarmac-runner-bootstrap.log"

BOOTSTRAP_LOG=""
RUNNER_LOG=""
EXIT_CODE_FILE=""
COMPLETION_MARKER_FILE=""
CACHE_ENV_FILE=""
SIGNING_IMPORT_SCRIPT_FILE=""

log() {
    local message="$1"
    local line
    line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') ${message}"
    echo "${line}" >> "${LOCAL_LOG}"
    if [[ -n "${BOOTSTRAP_LOG}" ]]; then
        echo "${line}" >> "${BOOTSTRAP_LOG}"
    fi
}

shutdown_guest() {
    if [[ "${TARMAC_SKIP_SHUTDOWN:-}" == "1" ]]; then
        log "Skipping guest shutdown because TARMAC_SKIP_SHUTDOWN=1"
        return
    fi

    log "Requesting guest shutdown"
    /sbin/shutdown -h now
}

finish() {
    local exit_code="$1"
    if [[ -n "${EXIT_CODE_FILE}" ]]; then
        echo "${exit_code}" > "${EXIT_CODE_FILE}"
    fi
    if [[ -n "${COMPLETION_MARKER_FILE}" ]]; then
        printf '{"exitCode":%s,"completedAt":"%s"}\n' "${exit_code}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" > "${COMPLETION_MARKER_FILE}"
    fi
    log "Bootstrap finished with exit code ${exit_code}"
    shutdown_guest
    exit "${exit_code}"
}

is_mounted() {
    local mount_point="$1"
    /sbin/mount | /usr/bin/grep -F " on ${mount_point} " >/dev/null 2>&1
}

mount_required_virtiofs() {
    local tag="$1"
    local mount_point="$2"

    /bin/mkdir -p "${mount_point}"
    if is_mounted "${mount_point}"; then
        log "VirtioFS tag ${tag} is already mounted at ${mount_point}"
        return 0
    fi

    local attempt
    for attempt in 1 2 3 4 5; do
        log "Mounting required VirtioFS tag ${tag} at ${mount_point} (attempt ${attempt})"
        if /sbin/mount_virtiofs "${tag}" "${mount_point}" >> "${LOCAL_LOG}" 2>&1; then
            log "Mounted VirtioFS tag ${tag} at ${mount_point}"
            return 0
        fi
        /bin/sleep 2
    done

    log "Required VirtioFS tag ${tag} could not be mounted"
    return 1
}

mount_optional_virtiofs() {
    local tag="$1"
    local mount_point="$2"

    /bin/mkdir -p "${mount_point}"
    if is_mounted "${mount_point}"; then
        log "Optional VirtioFS tag ${tag} is already mounted at ${mount_point}"
        return 0
    fi

    log "Trying optional VirtioFS tag ${tag} at ${mount_point}"
    if /sbin/mount_virtiofs "${tag}" "${mount_point}" >> "${LOCAL_LOG}" 2>&1; then
        log "Mounted optional VirtioFS tag ${tag} at ${mount_point}"
    else
        log "Optional VirtioFS tag ${tag} is not available"
    fi
}

prepare_shared_logging() {
    BOOTSTRAP_LOG="${SHARED_MOUNT}/bootstrap.log"
    RUNNER_LOG="${SHARED_MOUNT}/runner.log"
    EXIT_CODE_FILE="${SHARED_MOUNT}/exit-code"
    COMPLETION_MARKER_FILE="${SHARED_MOUNT}/completion.json"
    CACHE_ENV_FILE="${SHARED_MOUNT}/cache-env"
    SIGNING_IMPORT_SCRIPT_FILE="${SHARED_MOUNT}/apple-signing/import-signing-assets.sh"

    /usr/bin/touch "${BOOTSTRAP_LOG}" "${RUNNER_LOG}" "${EXIT_CODE_FILE}" 2>> "${LOCAL_LOG}" || {
        log "Cannot write bootstrap files into ${SHARED_MOUNT}"
        return 1
    }

    if [[ -f "${LOCAL_LOG}" ]]; then
        /bin/cat "${LOCAL_LOG}" >> "${BOOTSTRAP_LOG}"
    fi
}

ensure_cache_link() {
    local cache_path="$1"
    local guest_path="$2"

    /bin/mkdir -p "${cache_path}"
    /bin/mkdir -p "$(/usr/bin/dirname "${guest_path}")"

    if [[ -L "${guest_path}" ]]; then
        local existing
        existing="$(/bin/readlink "${guest_path}")"
        if [[ "${existing}" == "${cache_path}" ]]; then
            log "Cache link already configured: ${guest_path} -> ${cache_path}"
            return 0
        fi
        /bin/rm "${guest_path}"
    elif [[ -e "${guest_path}" ]]; then
        log "Cache path ${guest_path} already exists and is not a symlink; leaving it untouched"
        return 0
    fi

    /bin/ln -s "${cache_path}" "${guest_path}"
    log "Configured cache link: ${guest_path} -> ${cache_path}"
}

configure_cache_paths() {
    if ! is_mounted "${CACHE_MOUNT}"; then
        log "Actions cache mount is unavailable; runner will use clone-local tool caches"
        return 0
    fi

    local swiftpm_cache="${CACHE_MOUNT}/swiftpm"
    local derived_data_cache="${CACHE_MOUNT}/xcode-derived-data"
    local cocoapods_cache="${CACHE_MOUNT}/cocoapods"
    local pub_cache="${CACHE_MOUNT}/pub-cache"
    local npm_cache="${CACHE_MOUNT}/npm"
    local yarn_cache="${CACHE_MOUNT}/yarn"
    local pnpm_store="${CACHE_MOUNT}/pnpm-store"
    local bun_install_cache="${CACHE_MOUNT}/bun-install-cache"

    /bin/mkdir -p "${swiftpm_cache}" "${derived_data_cache}" "${cocoapods_cache}" "${pub_cache}" "${npm_cache}" "${yarn_cache}" "${pnpm_store}" "${bun_install_cache}"
    ensure_cache_link "${swiftpm_cache}" "/var/root/Library/Caches/org.swift.swiftpm"
    ensure_cache_link "${derived_data_cache}" "/var/root/Library/Developer/Xcode/DerivedData"
    ensure_cache_link "${cocoapods_cache}" "/var/root/.cocoapods"
    ensure_cache_link "${pub_cache}" "/var/root/.pub-cache"
    ensure_cache_link "${npm_cache}" "/var/root/.npm"
    ensure_cache_link "${yarn_cache}" "/var/root/.cache/yarn"
    ensure_cache_link "${pnpm_store}" "/var/root/.pnpm-store"
    ensure_cache_link "${bun_install_cache}" "/var/root/.bun/install/cache"

    /bin/cat > "${CACHE_ENV_FILE}" <<EOF
export TARMAC_ACTIONS_CACHE="${CACHE_MOUNT}"
export TARMAC_SWIFTPM_CACHE_PATH="${swiftpm_cache}"
export TARMAC_XCODE_DERIVED_DATA_PATH="${derived_data_cache}"
export TARMAC_COCOAPODS_CACHE_PATH="${cocoapods_cache}"
export TARMAC_FLUTTER_PUB_CACHE_PATH="${pub_cache}"
export PUB_CACHE="${pub_cache}"
export TARMAC_NPM_CACHE_PATH="${npm_cache}"
export NPM_CONFIG_CACHE="${npm_cache}"
export TARMAC_YARN_CACHE_PATH="${yarn_cache}"
export YARN_CACHE_FOLDER="${yarn_cache}"
export TARMAC_PNPM_STORE_PATH="${pnpm_store}"
export PNPM_STORE_PATH="${pnpm_store}"
export TARMAC_BUN_INSTALL_CACHE_PATH="${bun_install_cache}"
export BUN_INSTALL_CACHE_DIR="${bun_install_cache}"
EOF

    log "Configured actions cache environment at ${CACHE_ENV_FILE}"
}

configure_apple_signing() {
    if [[ ! -x "${SIGNING_IMPORT_SCRIPT_FILE}" ]]; then
        log "No Apple signing injection requested"
        return 0
    fi

    log "Configuring ephemeral Apple signing assets"
    # shellcheck disable=SC1090
    if . "${SIGNING_IMPORT_SCRIPT_FILE}" >> "${LOCAL_LOG}" 2>&1; then
        log "Ephemeral Apple signing assets are available for the runner"
        return 0
    fi

    log "Failed to configure ephemeral Apple signing assets"
    return 1
}

validate_job_payload() {
    local runner_dir="${SHARED_MOUNT}/runner"
    local run_script="${runner_dir}/run.sh"
    local jit_config="${SHARED_MOUNT}/jitconfig"

    if [[ ! -d "${runner_dir}" ]]; then
        log "Missing runner package at ${runner_dir}"
        return 1
    fi

    if [[ ! -x "${run_script}" ]]; then
        log "Missing executable runner entrypoint at ${run_script}"
        return 1
    fi

    if [[ ! -s "${jit_config}" ]]; then
        log "Missing or empty JIT config at ${jit_config}"
        return 1
    fi
}

run_runner() {
    local runner_dir="${SHARED_MOUNT}/runner"
    local jit_config="${SHARED_MOUNT}/jitconfig"

    log "Starting GitHub Actions runner"
    (
        cd "${runner_dir}" || exit 127
        if [[ -f "${CACHE_ENV_FILE}" ]]; then
            # shellcheck disable=SC1090
            . "${CACHE_ENV_FILE}"
        fi
        ./run.sh --jitconfig "${jit_config}"
    ) >> "${RUNNER_LOG}" 2>&1
    return "$?"
}

main() {
    log "Tarmac guest bootstrap starting"

    if ! mount_required_virtiofs "${SHARED_TAG}" "${SHARED_MOUNT}"; then
        finish 10
    fi

    if ! prepare_shared_logging; then
        finish 11
    fi

    mount_optional_virtiofs "${CACHE_TAG}" "${CACHE_MOUNT}"
    configure_cache_paths
    if ! configure_apple_signing; then
        finish 13
    fi

    if ! validate_job_payload; then
        finish 12
    fi

    run_runner
    local runner_exit_code="$?"
    log "Runner exited with code ${runner_exit_code}"
    finish "${runner_exit_code}"
}

main "$@"
