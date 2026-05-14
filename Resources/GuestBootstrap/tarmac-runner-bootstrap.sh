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

    /usr/bin/touch "${BOOTSTRAP_LOG}" "${RUNNER_LOG}" "${EXIT_CODE_FILE}" 2>> "${LOCAL_LOG}" || {
        log "Cannot write bootstrap files into ${SHARED_MOUNT}"
        return 1
    }

    if [[ -f "${LOCAL_LOG}" ]]; then
        /bin/cat "${LOCAL_LOG}" >> "${BOOTSTRAP_LOG}"
    fi
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

    if ! validate_job_payload; then
        finish 12
    fi

    run_runner
    local runner_exit_code="$?"
    log "Runner exited with code ${runner_exit_code}"
    finish "${runner_exit_code}"
}

main "$@"
