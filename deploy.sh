#!/usr/bin/env bash
# ==============================================================================
# deploy.sh - Main Idempotent Deployment & Security Hardening Orchestrator
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ------------------------------------------------------------------------------
# Error & Signal Trapping
# ------------------------------------------------------------------------------
on_error() {
    local exit_code="$1"
    local line_no="$2"
    printf '[ERROR] Deployment failed at line %s (exit code: %s)\n' "${line_no}" "${exit_code}" >&2
    exit "${exit_code}"
}

on_signal() {
    printf '[WARN] Deployment interrupted by signal. Exiting cleanly.\n' >&2
    exit 130
}

trap 'on_error $? ${LINENO}' ERR
trap 'on_signal' INT TERM

log_info() {
    printf '[INFO] [deploy] %s\n' "$1"
}

# ------------------------------------------------------------------------------
# 1. Root Validation
# ------------------------------------------------------------------------------
if [[ "${EUID}" -ne 0 ]]; then
    printf '[ERROR] This script must be run as root (e.g., sudo ./deploy.sh).\n' >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. Distro Detection via /etc/os-release
# ------------------------------------------------------------------------------
if [[ ! -r /etc/os-release ]]; then
    printf '[ERROR] /etc/os-release not found; cannot detect Linux distribution.\n' >&2
    exit 1
fi

# shellcheck source=/dev/null
source /etc/os-release

case "${ID:-}" in
    ubuntu|debian)
        OS_FAMILY="debian"
        ;;
    rhel|almalinux|rocky|centos|ol)
        OS_FAMILY="rhel"
        ;;
    *)
        if [[ "${ID_LIKE:-}" == *"debian"* ]]; then
            OS_FAMILY="debian"
        elif [[ "${ID_LIKE:-}" == *"rhel"* ]] || [[ "${ID_LIKE:-}" == *"fedora"* ]]; then
            OS_FAMILY="rhel"
        else
            printf '[ERROR] Unsupported OS: %s (supported: RHEL/AlmaLinux/Rocky, Debian/Ubuntu)\n' "${ID:-unknown}" >&2
            exit 1
        fi
        ;;
esac
export OS_FAMILY
log_info "Detected distribution: ${PRETTY_NAME:-${ID:-unknown}} (family: ${OS_FAMILY})"

# ------------------------------------------------------------------------------
# 3. Validate & Load .env
# ------------------------------------------------------------------------------
ENV_FILE="${SCRIPT_DIR}/.env"
if [[ ! -f "${ENV_FILE}" ]]; then
    printf '[ERROR] Missing .env file at %s\n' "${ENV_FILE}" >&2
    printf '        Run: cp .env.example .env && nano .env\n' >&2
    exit 1
fi

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

export APP_USER="${APP_USER:-webapp}"
export APP_DIR="${APP_DIR:-/opt/webapp}"
export LOG_DIR="${LOG_DIR:-/var/log/webapp}"
export APP_PORT="${APP_PORT:-8000}"
export SERVER_NAME="${SERVER_NAME:-_}"

# ------------------------------------------------------------------------------
# 4. Module 01: Users & Directories
# ------------------------------------------------------------------------------
log_info "Step 1/4: Running scripts/01_setup_users.sh..."
bash "${SCRIPT_DIR}/scripts/01_setup_users.sh"

# ------------------------------------------------------------------------------
# 5. Module 02: Dependencies
# ------------------------------------------------------------------------------
log_info "Step 2/4: Running scripts/02_install_deps.sh..."
bash "${SCRIPT_DIR}/scripts/02_install_deps.sh"

# ------------------------------------------------------------------------------
# 6. Deploy .env, Systemd Service & Nginx Reverse Proxy
# ------------------------------------------------------------------------------
log_info "Step 3/4: Deploying .env, systemd unit, and Nginx configuration..."

install -m 0640 -o root -g "${APP_USER}" "${ENV_FILE}" "${APP_DIR}/.env"

SYSTEMD_SRC="${SCRIPT_DIR}/systemd/webapp.service"
SYSTEMD_DEST="/etc/systemd/system/webapp.service"
if ! cmp -s "${SYSTEMD_SRC}" "${SYSTEMD_DEST}" 2>/dev/null; then
    install -m 0644 -o root -g root "${SYSTEMD_SRC}" "${SYSTEMD_DEST}"
    systemctl daemon-reload
    systemctl enable --now webapp.service
    systemctl restart webapp.service
else
    systemctl daemon-reload
    systemctl enable --now webapp.service
fi

NGINX_TEMPLATE="${SCRIPT_DIR}/configs/nginx.conf.template"
NGINX_CONF_DEST="/etc/nginx/conf.d/webapp.conf"
mkdir -p /etc/nginx/conf.d
envsubst '${APP_PORT} ${SERVER_NAME}' < "${NGINX_TEMPLATE}" > "${NGINX_CONF_DEST}"
chmod 0644 "${NGINX_CONF_DEST}"

if [[ "${OS_FAMILY}" == "debian" ]] && [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
fi

log_info "Validating Nginx configuration..."
nginx -t
systemctl enable --now nginx
systemctl reload nginx

# ------------------------------------------------------------------------------
# 7. Module 03: Security Hardening
# ------------------------------------------------------------------------------
log_info "Step 4/4: Running scripts/03_configure_sec.sh..."
bash "${SCRIPT_DIR}/scripts/03_configure_sec.sh"

log_info "Deployment completed successfully."
