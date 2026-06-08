#!/bin/bash
set -u -o pipefail

PATH="/usr/bin:/bin:/usr/sbin:/sbin"

SHARED_TAG="shared"
SHARED_MOUNT="/Volumes/tarmac-shared"
SHARED_AUTOMOUNT="/Volumes/My Shared Files"
CACHE_TAG="actions-cache"
CACHE_MOUNT="/Volumes/actions-cache"
LOCAL_LOG="/var/log/tarmac-runner-bootstrap.log"
RUNNER_USER="tarmac"
RUNNER_UID="501"
RUNNER_GID="20"
RUNNER_HOME="/Users/tarmac"

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
        runner_shell "printf '%s\\n' $(shell_quote "${line}") >> $(shell_quote "${BOOTSTRAP_LOG}")" 2>> "${LOCAL_LOG}" || true
    fi
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | /usr/bin/sed "s/'/'\\\\''/g")"
}

ensure_runner_user() {
    if /usr/bin/id -u "${RUNNER_USER}" >/dev/null 2>&1; then
        /usr/bin/dscl . -create "/Users/${RUNNER_USER}" NFSHomeDirectory "${RUNNER_HOME}" >> "${LOCAL_LOG}" 2>&1 || true
        /bin/mkdir -p "${RUNNER_HOME}"
        /usr/sbin/chown -R "${RUNNER_UID}:${RUNNER_GID}" "${RUNNER_HOME}" >> "${LOCAL_LOG}" 2>&1
        return 0
    fi

    log "Creating guest runner user ${RUNNER_USER} (${RUNNER_UID}:${RUNNER_GID})"
    /usr/bin/dscl . -create "/Users/${RUNNER_USER}" >> "${LOCAL_LOG}" 2>&1
    /usr/bin/dscl . -create "/Users/${RUNNER_USER}" UserShell /bin/bash >> "${LOCAL_LOG}" 2>&1
    /usr/bin/dscl . -create "/Users/${RUNNER_USER}" RealName "Tarmac Runner" >> "${LOCAL_LOG}" 2>&1
    /usr/bin/dscl . -create "/Users/${RUNNER_USER}" UniqueID "${RUNNER_UID}" >> "${LOCAL_LOG}" 2>&1
    /usr/bin/dscl . -create "/Users/${RUNNER_USER}" PrimaryGroupID "${RUNNER_GID}" >> "${LOCAL_LOG}" 2>&1
    /usr/bin/dscl . -create "/Users/${RUNNER_USER}" NFSHomeDirectory "${RUNNER_HOME}" >> "${LOCAL_LOG}" 2>&1
    /bin/mkdir -p "${RUNNER_HOME}"
    /usr/sbin/chown -R "${RUNNER_UID}:${RUNNER_GID}" "${RUNNER_HOME}" >> "${LOCAL_LOG}" 2>&1
}

runner_shell() {
    HOME="${RUNNER_HOME}" USER="${RUNNER_USER}" LOGNAME="${RUNNER_USER}" /usr/bin/su -m "${RUNNER_USER}" -c "$1"
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
        runner_shell "printf '%s\\n' $(shell_quote "${exit_code}") > $(shell_quote "${EXIT_CODE_FILE}")" 2>> "${LOCAL_LOG}" || true
    fi
    if [[ -n "${COMPLETION_MARKER_FILE}" ]]; then
        local completion
        completion="$(printf '{"exitCode":%s,"completedAt":"%s"}\n' "${exit_code}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
        runner_shell "printf '%s\\n' $(shell_quote "${completion}") > $(shell_quote "${COMPLETION_MARKER_FILE}")" 2>> "${LOCAL_LOG}" || true
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

    if [[ "${tag}" == "${SHARED_TAG}" && -d "${SHARED_AUTOMOUNT}" ]]; then
        SHARED_MOUNT="${SHARED_AUTOMOUNT}"
        log "Using macOS automounted VirtioFS share at ${SHARED_MOUNT}"
        return 0
    fi

    /bin/mkdir -p "${mount_point}"
    if is_mounted "${mount_point}"; then
        log "VirtioFS tag ${tag} is already mounted at ${mount_point}"
        return 0
    fi

    local attempt=1
    while [[ "${attempt}" -le 30 ]]; do
        log "Mounting required VirtioFS tag ${tag} at ${mount_point} (attempt ${attempt})"
        if /sbin/mount_virtiofs "${tag}" "${mount_point}" >> "${LOCAL_LOG}" 2>&1; then
            log "Mounted VirtioFS tag ${tag} at ${mount_point}"
            return 0
        fi
        /bin/sleep 2
        attempt=$((attempt + 1))
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

    /sbin/mount >> "${LOCAL_LOG}" 2>&1 || true
    /bin/ls -ldeO@ "${SHARED_MOUNT}" >> "${LOCAL_LOG}" 2>&1 || true

    runner_shell ": >> $(shell_quote "${BOOTSTRAP_LOG}") && : >> $(shell_quote "${RUNNER_LOG}") && : >> $(shell_quote "${EXIT_CODE_FILE}")" 2>> "${LOCAL_LOG}" || {
        log "Cannot write bootstrap files into ${SHARED_MOUNT}"
        return 1
    }

    if [[ -f "${LOCAL_LOG}" ]]; then
        runner_shell "cat $(shell_quote "${LOCAL_LOG}") >> $(shell_quote "${BOOTSTRAP_LOG}")" 2>> "${LOCAL_LOG}" || true
    fi
}

ensure_cache_link() {
    local cache_path="$1"
    local guest_path="$2"

    /bin/mkdir -p "${cache_path}"
    /bin/chmod -R 0777 "${cache_path}" >> "${LOCAL_LOG}" 2>&1 || true
    /bin/mkdir -p "$(/usr/bin/dirname "${guest_path}")"
    /usr/sbin/chown -R "${RUNNER_UID}:${RUNNER_GID}" "$(/usr/bin/dirname "${guest_path}")" >> "${LOCAL_LOG}" 2>&1 || true

    if [[ -L "${guest_path}" ]]; then
        local existing
        existing="$(/bin/readlink "${guest_path}")"
        if [[ "${existing}" == "${cache_path}" ]]; then
            log "Cache link already configured: ${guest_path} -> ${cache_path}"
            return 0
        fi
        /bin/rm "${guest_path}"
    elif [[ -e "${guest_path}" ]]; then
        log "Cache path ${guest_path} already exists and is not a symlink; repairing runner ownership"
        /usr/sbin/chown -R "${RUNNER_UID}:${RUNNER_GID}" "${guest_path}" >> "${LOCAL_LOG}" 2>&1 || true
        /bin/chmod -R u+rwX "${guest_path}" >> "${LOCAL_LOG}" 2>&1 || true
        return 0
    fi

    /bin/ln -s "${cache_path}" "${guest_path}"
    /usr/sbin/chown -h "${RUNNER_UID}:${RUNNER_GID}" "${guest_path}" >> "${LOCAL_LOG}" 2>&1 || true
    log "Configured cache link: ${guest_path} -> ${cache_path}"
}

ensure_local_cache_dirs() {
    local swiftpm_cache="${RUNNER_HOME}/Library/Caches/org.swift.swiftpm"
    local module_cache="${RUNNER_HOME}/.cache/clang/ModuleCache"

    /bin/mkdir -p "${swiftpm_cache}" "${module_cache}"
    /usr/sbin/chown -R "${RUNNER_UID}:${RUNNER_GID}" \
        "${RUNNER_HOME}/Library" \
        "${RUNNER_HOME}/.cache" >> "${LOCAL_LOG}" 2>&1 || true
    /bin/chmod -R u+rwX "${RUNNER_HOME}/Library" "${RUNNER_HOME}/.cache" >> "${LOCAL_LOG}" 2>&1 || true
}

configure_cache_paths() {
    ensure_local_cache_dirs

    if ! is_mounted "${CACHE_MOUNT}"; then
        log "Actions cache mount is unavailable; runner will use clone-local tool caches"
        return 0
    fi

    local swiftpm_cache="${CACHE_MOUNT}/swiftpm"
    local cocoapods_cache="${CACHE_MOUNT}/cocoapods"
    local pub_cache="${CACHE_MOUNT}/pub-cache"
    local npm_cache="${CACHE_MOUNT}/npm"
    local yarn_cache="${CACHE_MOUNT}/yarn"
    local pnpm_store="${CACHE_MOUNT}/pnpm-store"
    local bun_install_cache="${CACHE_MOUNT}/bun-install-cache"

    /bin/mkdir -p "${swiftpm_cache}" "${cocoapods_cache}" "${pub_cache}" "${npm_cache}" "${yarn_cache}" "${pnpm_store}" "${bun_install_cache}"
    ensure_cache_link "${swiftpm_cache}" "${RUNNER_HOME}/Library/Caches/org.swift.swiftpm"
    ensure_cache_link "${cocoapods_cache}" "${RUNNER_HOME}/.cocoapods"
    ensure_cache_link "${pub_cache}" "${RUNNER_HOME}/.pub-cache"
    ensure_cache_link "${npm_cache}" "${RUNNER_HOME}/.npm"
    ensure_cache_link "${yarn_cache}" "${RUNNER_HOME}/.cache/yarn"
    ensure_cache_link "${pnpm_store}" "${RUNNER_HOME}/.pnpm-store"
    ensure_cache_link "${bun_install_cache}" "${RUNNER_HOME}/.bun/install/cache"

    /bin/cat > "${CACHE_ENV_FILE}" <<EOF
export TARMAC_ACTIONS_CACHE="${CACHE_MOUNT}"
export TARMAC_SWIFTPM_CACHE_PATH="${swiftpm_cache}"
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

ensure_xcode_first_launch() {
    local xcodebuild="/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild"
    if [[ ! -x "${xcodebuild}" ]]; then
        log "Xcode is not installed; skipping xcodebuild first launch"
        return 0
    fi

    log "Running xcodebuild first-launch setup"
    if DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" "${xcodebuild}" -runFirstLaunch >> "${LOCAL_LOG}" 2>&1; then
        log "xcodebuild first-launch setup completed"
        return 0
    fi

    log "xcodebuild first-launch setup failed"
    return 1
}

validate_job_payload() {
    local runner_dir="${SHARED_MOUNT}/runner"
    local run_script="${runner_dir}/run.sh"
    local jit_config="${SHARED_MOUNT}/jitconfig"
    local registration_token="${SHARED_MOUNT}/registration-token"
    local runner_url="${SHARED_MOUNT}/runner-url"
    local runner_name="${SHARED_MOUNT}/runner-name"
    local runner_labels="${SHARED_MOUNT}/runner-labels"

    if [[ ! -d "${runner_dir}" ]]; then
        log "Missing runner package at ${runner_dir}"
        return 1
    fi

    if [[ ! -x "${run_script}" ]]; then
        log "Missing executable runner entrypoint at ${run_script}"
        return 1
    fi

    if [[ -s "${jit_config}" ]]; then
        return 0
    fi

    if [[ -s "${registration_token}" && -s "${runner_url}" && -s "${runner_name}" && -s "${runner_labels}" ]]; then
        return 0
    fi

    log "Missing runner registration payload (jitconfig or registration-token files)"
    return 1
}

configure_runner_with_registration_token() {
    local runner_dir="${SHARED_MOUNT}/runner"
    local registration_token
    local runner_url
    local runner_name
    local runner_labels

    registration_token="$(/bin/cat "${SHARED_MOUNT}/registration-token")"
    runner_url="$(/bin/cat "${SHARED_MOUNT}/runner-url")"
    runner_name="$(/bin/cat "${SHARED_MOUNT}/runner-name")"
    runner_labels="$(/bin/cat "${SHARED_MOUNT}/runner-labels")"

    log "Configuring GitHub Actions runner with registration token"
    (
        cd "${runner_dir}" || exit 127
        ./config.sh \
            --url "${runner_url}" \
            --token "${registration_token}" \
            --name "${runner_name}" \
            --labels "${runner_labels}" \
            --unattended \
            --replace
    ) >> "${RUNNER_LOG}" 2>&1
}

run_runner() {
    local runner_dir="${SHARED_MOUNT}/runner"
    local jit_config="${SHARED_MOUNT}/jitconfig"
    local registration_token="${SHARED_MOUNT}/registration-token"
    local quoted_runner_dir
    local quoted_cache_env
    local quoted_jit_config
    local quoted_registration_token

    quoted_runner_dir="$(shell_quote "${runner_dir}")"
    quoted_cache_env="$(shell_quote "${CACHE_ENV_FILE}")"
    quoted_jit_config="$(shell_quote "${jit_config}")"
    quoted_registration_token="$(shell_quote "${registration_token}")"

    log "Starting GitHub Actions runner"
    runner_shell "
        cd ${quoted_runner_dir} || exit 127
        if [[ -f ${quoted_cache_env} ]]; then
            . ${quoted_cache_env}
        fi
        if [[ -s ${quoted_jit_config} ]]; then
            jit_payload=\"\$(/bin/cat ${quoted_jit_config})\"
            ./run.sh --jitconfig \"\${jit_payload}\"
        elif [[ -s ${quoted_registration_token} ]]; then
            configure_runner_with_registration_token || exit "$?"
            ./run.sh
        else
            exit 12
        fi
    " >> "${RUNNER_LOG}" 2>&1
    return "$?"
}

write_job_result() {
    local exit_code="$1"
    if [[ -n "${EXIT_CODE_FILE}" ]]; then
        runner_shell "printf '%s\\n' $(shell_quote "${exit_code}") > $(shell_quote "${EXIT_CODE_FILE}")" 2>> "${LOCAL_LOG}" || true
    fi
    if [[ -n "${COMPLETION_MARKER_FILE}" ]]; then
        local completion
        completion="$(printf '{"exitCode":%s,"completedAt":"%s"}\n' "${exit_code}" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')")"
        runner_shell "printf '%s\\n' $(shell_quote "${completion}") > $(shell_quote "${COMPLETION_MARKER_FILE}")" 2>> "${LOCAL_LOG}" || true
    fi
    log "Job finished with exit code ${exit_code}"
}

reset_job_artifacts() {
    /bin/rm -f "${SHARED_MOUNT}/exit-code" "${SHARED_MOUNT}/completion.json" "${SHARED_MOUNT}/job-ready" 2>> "${LOCAL_LOG}" || true
    : > "${RUNNER_LOG}"
}

warm_mode_enabled() {
    [[ -f "${SHARED_MOUNT}/warm-mode" ]]
}

warm_shutdown_requested() {
    [[ -f "${SHARED_MOUNT}/warm-shutdown" ]]
}

wait_for_job_ready() {
    local timeout_seconds="${1:-86400}"
    local deadline=$(( $(/bin/date +%s) + timeout_seconds ))

    while [[ $(/bin/date +%s) -lt "${deadline}" ]]; do
        if warm_shutdown_requested; then
            log "Warm shutdown requested by host"
            return 2
        fi
        if [[ -f "${SHARED_MOUNT}/job-ready" ]]; then
            log "Host signaled job-ready"
            return 0
        fi
        /bin/sleep 2
    done

    log "Timed out waiting for job-ready"
    return 1
}

run_single_job() {
    if ! validate_job_payload; then
        return 12
    fi

    run_runner
    local runner_exit_code="$?"
    log "Runner exited with code ${runner_exit_code}"
    write_job_result "${runner_exit_code}"
    return "${runner_exit_code}"
}

run_warm_loop() {
    log "Warm runner mode enabled"
    export TARMAC_SKIP_SHUTDOWN=1

    while true; do
        reset_job_artifacts
        wait_for_job_ready 86400
        local wait_status="$?"
        if [[ "${wait_status}" -eq 2 ]]; then
            finish 0
        fi
        if [[ "${wait_status}" -ne 0 ]]; then
            finish 14
        fi

        /bin/rm -f "${SHARED_MOUNT}/job-ready" 2>> "${LOCAL_LOG}" || true

        if warm_shutdown_requested; then
            finish 0
        fi

        if ! configure_apple_signing; then
            write_job_result 13
            continue
        fi

        run_single_job

        if ! warm_mode_enabled; then
            shutdown_guest
            exit "$?"
        fi
    done
}

main() {
    log "Tarmac guest bootstrap starting"
    ensure_runner_user

    if ! mount_required_virtiofs "${SHARED_TAG}" "${SHARED_MOUNT}"; then
        finish 10
    fi

    if ! prepare_shared_logging; then
        finish 11
    fi

    mount_optional_virtiofs "${CACHE_TAG}" "${CACHE_MOUNT}"
    configure_cache_paths
    if ! ensure_xcode_first_launch; then
        finish 23
    fi

    if warm_mode_enabled; then
        run_warm_loop
    fi

    if ! configure_apple_signing; then
        finish 13
    fi

    run_single_job
    local runner_exit_code="$?"
    finish "${runner_exit_code}"
}

main "$@"
