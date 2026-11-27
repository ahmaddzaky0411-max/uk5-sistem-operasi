#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"

log_info() {
    printf '[INFO] [01_setup_users] %s\n' "$1"
}

log_error() {
    printf '[ERROR] [01_setup_users] %s\n' "$1" >&2
}

on_error() {
    local exit_code="$1"
    local line_no="$2"
    log_error "Script failed at line ${line_no} (exit code: ${exit_code})"
    exit "${exit_code}"
}

on_signal() {
    printf '[WARN] [01_setup_users] Interrupted by signal. Exiting cleanly.\n' >&2
    exit 130
}

trap 'on_error $? ${LINENO}' ERR
trap 'on_signal' INT TERM

load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        set -a
        source "${ENV_FILE}"
        set +a
    elif [[ -z "${APP_USER:-}" ]] || [[ -z "${APP_DIR:-}" ]] || [[ -z "${LOG_DIR:-}" ]]; then
        log_error "Missing .env file at ${ENV_FILE}"
        printf '        Run: cp .env.example .env && nano .env\n' >&2
        exit 1
    fi

    APP_USER="${APP_USER:-}"
    APP_GROUP="${APP_GROUP:-${APP_USER}}"
    APP_DIR="${APP_DIR:-}"
    LOG_DIR="${LOG_DIR:-}"
}

validate_required_vars() {
    local required_vars=("APP_USER" "APP_GROUP" "APP_DIR" "LOG_DIR")
    local missing=0
    local var_name

    for var_name in "${required_vars[@]}"; do
        if [[ -z "${!var_name:-}" ]]; then
            log_error "Required environment variable '${var_name}' is not set or empty."
            missing=1
        fi
    done

    if [[ "${missing}" -ne 0 ]]; then
        log_error "Please configure all required variables in ${ENV_FILE} (see .env.example)."
        exit 1
    fi

    if [[ "${APP_USER}" == "root" ]] || [[ ! "${APP_USER}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "Invalid APP_USER '${APP_USER}': must be a non-root lowercase Linux username."
        exit 1
    fi

    if [[ "${APP_GROUP}" == "root" ]] || [[ ! "${APP_GROUP}" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_error "Invalid APP_GROUP '${APP_GROUP}': must be a non-root lowercase Linux group name."
        exit 1
    fi

    if [[ "${APP_DIR}" != /* ]] || [[ "${APP_DIR}" == "/" ]]; then
        log_error "Invalid APP_DIR '${APP_DIR}': must be a non-root absolute path."
        exit 1
    fi

    if [[ "${LOG_DIR}" != /* ]] || [[ "${LOG_DIR}" == "/" ]]; then
        log_error "Invalid LOG_DIR '${LOG_DIR}': must be a non-root absolute path."
        exit 1
    fi
}

setup_group() {
    if getent group "${APP_GROUP}" >/dev/null 2>&1; then
        log_info "Group '${APP_GROUP}' already exists. Skipping."
    else
        log_info "Creating system group '${APP_GROUP}'..."
        groupadd --system "${APP_GROUP}"
    fi
}

setup_user() {
    local nologin_shell="/usr/sbin/nologin"
    if [[ ! -x "${nologin_shell}" ]]; then
        if [[ -x "/sbin/nologin" ]]; then
            nologin_shell="/sbin/nologin"
        else
            nologin_shell="/bin/false"
        fi
    fi

    if id -u "${APP_USER}" >/dev/null 2>&1; then
        local uid
        local current_group
        uid="$(id -u "${APP_USER}")"
        current_group="$(id -gn "${APP_USER}")"
        log_info "User '${APP_USER}' already exists (uid=${uid})."
        if [[ "${current_group}" != "${APP_GROUP}" ]]; then
            log_info "Updating primary group of '${APP_USER}' to '${APP_GROUP}'..."
            usermod -g "${APP_GROUP}" "${APP_USER}"
        fi
    else
        log_info "Creating system user '${APP_USER}'..."
        useradd --system \
            --gid "${APP_GROUP}" \
            --home-dir "${APP_DIR}" \
            --no-create-home \
            --shell "${nologin_shell}" \
            --comment "Web application service account" \
            "${APP_USER}"
    fi
}

setup_directories() {
    local dirs=("${APP_DIR}" "${LOG_DIR}")
    local dir

    for dir in "${dirs[@]}"; do
        if [[ ! -d "${dir}" ]]; then
            log_info "Creating directory '${dir}'..."
            mkdir -p "${dir}"
        else
            log_info "Directory '${dir}' already exists."
        fi
        chown "${APP_USER}:${APP_GROUP}" "${dir}"
        chmod 0750 "${dir}"
        log_info "Ensured ownership (${APP_USER}:${APP_GROUP}) and mode (0750) on '${dir}'."
    done
}

main() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root (e.g., sudo bash scripts/01_setup_users.sh)."
        exit 1
    fi

    load_env
    validate_required_vars
    setup_group
    setup_user
    setup_directories

    log_info "User, group, and directory setup completed successfully."
}

main "$@"
