#!/usr/bin/env bash
# ==============================================================================
# scripts/02_install_deps.sh - Cross-Distro Package & Database Provisioning
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${PROJECT_ROOT}/.env}"
TMP_DB_CNF=""

# ------------------------------------------------------------------------------
# Logging, Cleanup & Error Trapping
# ------------------------------------------------------------------------------
log_info() {
    printf '[INFO] [02_install_deps] %s\n' "$1"
}

log_error() {
    printf '[ERROR] [02_install_deps] %s\n' "$1" >&2
}

cleanup() {
    if [[ -n "${TMP_DB_CNF}" ]] && [[ -f "${TMP_DB_CNF}" ]]; then
        rm -f "${TMP_DB_CNF}"
    fi
}

on_error() {
    local exit_code="$1"
    local line_no="$2"
    log_error "Script failed at line ${line_no} (exit code: ${exit_code})"
    exit "${exit_code}"
}

on_signal() {
    printf '[WARN] [02_install_deps] Interrupted by signal. Exiting cleanly.\n' >&2
    exit 130
}

trap 'cleanup' EXIT
trap 'on_error $? ${LINENO}' ERR
trap 'on_signal' INT TERM

# ------------------------------------------------------------------------------
# Load & Validate Environment Variables
# ------------------------------------------------------------------------------
load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${ENV_FILE}"
        set +a
    elif [[ -z "${DB_NAME:-}" ]] || [[ -z "${DB_USER:-}" ]] || [[ -z "${DB_PASS:-}" ]]; then
        log_error "Missing .env file at ${ENV_FILE}"
        printf '        Run: cp .env.example .env && nano .env\n' >&2
        exit 1
    fi

    APP_USER="${APP_USER:-}"
    APP_GROUP="${APP_GROUP:-${APP_USER}}"
    APP_DIR="${APP_DIR:-}"
    LOG_DIR="${LOG_DIR:-}"
    APP_PORT="${APP_PORT:-}"
    SERVER_NAME="${SERVER_NAME:-}"
    DB_HOST="${DB_HOST:-}"
    DB_PORT="${DB_PORT:-}"
    DB_NAME="${DB_NAME:-}"
    DB_USER="${DB_USER:-}"
    DB_PASS="${DB_PASS:-}"
}

validate_port() {
    local name="$1"
    local value="$2"

    if [[ ! "${value}" =~ ^[0-9]+$ ]] || (( value < 1 || value > 65535 )); then
        log_error "Invalid ${name} '${value}': must be an integer between 1 and 65535."
        exit 1
    fi
}

validate_required_vars() {
    local required_vars=(
        "APP_USER"
        "APP_GROUP"
        "APP_DIR"
        "LOG_DIR"
        "APP_PORT"
        "SERVER_NAME"
        "DB_HOST"
        "DB_PORT"
        "DB_NAME"
        "DB_USER"
        "DB_PASS"
    )
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

    validate_port "APP_PORT" "${APP_PORT}"
    validate_port "DB_PORT" "${DB_PORT}"

    if [[ ! "${DB_NAME}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid DB_NAME '${DB_NAME}': only alphanumeric characters and underscores are allowed."
        exit 1
    fi

    if [[ "${DB_USER}" == "root" ]] || [[ ! "${DB_USER}" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
        log_error "Invalid DB_USER '${DB_USER}': must be a non-root identifier (alphanumeric and underscores)."
        exit 1
    fi

    if [[ "${DB_PASS}" == CHANGE_ME* ]] || [[ "${DB_PASS}" == "changeme" ]]; then
        log_error "DB_PASS still uses a placeholder value. Set a strong password in ${ENV_FILE}."
        exit 1
    fi
}

# ------------------------------------------------------------------------------
# Distro Detection (Supports Standalone Execution & deploy.sh Export)
# ------------------------------------------------------------------------------
detect_os_family() {
    if [[ -n "${OS_FAMILY:-}" ]]; then
        case "${OS_FAMILY}" in
            debian|rhel)
                return 0
                ;;
            *)
                log_error "Unsupported OS_FAMILY '${OS_FAMILY}'."
                exit 1
                ;;
        esac
    fi

    if [[ ! -r /etc/os-release ]]; then
        log_error "/etc/os-release not found; cannot detect Linux distribution."
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
                log_error "Unsupported OS: ${ID:-unknown} (supported: RHEL/AlmaLinux/Rocky, Debian/Ubuntu)."
                exit 1
            fi
            ;;
    esac
    export OS_FAMILY
}

# ------------------------------------------------------------------------------
# Idempotent Package Installation
# ------------------------------------------------------------------------------
install_debian_packages() {
    log_info "Updating apt cache and installing Debian/Ubuntu packages..."
    export DEBIAN_FRONTEND=noninteractive
    DEBIAN_FRONTEND=noninteractive apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        nginx \
        mariadb-server \
        mariadb-client \
        gettext-base \
        python3 \
        python3-pip \
        python3-venv \
        curl \
        ca-certificates
}

install_rhel_packages() {
    local pkg_mgr="dnf"
    if ! command -v dnf >/dev/null 2>&1; then
        pkg_mgr="yum"
    fi

    log_info "Refreshing ${pkg_mgr} metadata and installing RHEL packages..."
    "${pkg_mgr}" makecache -y

    local packages=(
        nginx
        mariadb-server
        mariadb
        gettext
        python3
        python3-pip
        ca-certificates
    )

    if ! command -v curl >/dev/null 2>&1; then
        packages+=(curl)
    fi

    "${pkg_mgr}" install -y "${packages[@]}"
}

install_packages() {
    case "${OS_FAMILY}" in
        debian)
            install_debian_packages
            ;;
        rhel)
            install_rhel_packages
            ;;
        *)
            log_error "Unsupported OS_FAMILY '${OS_FAMILY}'."
            exit 1
            ;;
    esac
}

# ------------------------------------------------------------------------------
# MariaDB Configuration & Idempotent Database Provisioning
# ------------------------------------------------------------------------------
run_db_admin() {
    local db_admin="$1"
    shift
    if [[ -n "${TMP_DB_CNF}" ]]; then
        "${db_admin}" "--defaults-extra-file=${TMP_DB_CNF}" "$@"
    else
        "${db_admin}" "$@"
    fi
}

run_db_client() {
    local db_client="$1"
    if [[ -n "${TMP_DB_CNF}" ]]; then
        "${db_client}" "--defaults-extra-file=${TMP_DB_CNF}"
    else
        "${db_client}"
    fi
}

configure_database() {
    local db_conf_src="${PROJECT_ROOT}/configs/database.cnf"
    local db_conf_dir
    local db_conf_dest
    local db_conf_changed=0

    if [[ ! -f "${db_conf_src}" ]]; then
        log_error "Missing MariaDB configuration template at ${db_conf_src}."
        exit 1
    fi

    if [[ "${DB_HOST}" != "localhost" ]] && [[ "${DB_HOST}" != "127.0.0.1" ]]; then
        log_info "DB_HOST is '${DB_HOST}' (remote); skipping local MariaDB server provisioning."
        return 0
    fi

    if [[ "${OS_FAMILY}" == "debian" ]]; then
        db_conf_dir="/etc/mysql/mariadb.conf.d"
    else
        db_conf_dir="/etc/my.cnf.d"
    fi
    db_conf_dest="${db_conf_dir}/99-webapp.cnf"

    mkdir -p "${db_conf_dir}"
    if ! cmp -s "${db_conf_src}" "${db_conf_dest}" 2>/dev/null; then
        log_info "Installing MariaDB configuration to '${db_conf_dest}'..."
        install -m 0644 -o root -g root "${db_conf_src}" "${db_conf_dest}"
        db_conf_changed=1
    else
        log_info "MariaDB configuration '${db_conf_dest}' is already up to date."
    fi

    systemctl enable --now mariadb
    if [[ "${db_conf_changed}" -eq 1 ]]; then
        log_info "Restarting MariaDB to apply updated configuration..."
        systemctl restart mariadb
    fi

    local db_admin=""
    local db_client=""
    if command -v mariadb-admin >/dev/null 2>&1; then
        db_admin="mariadb-admin"
    elif command -v mysqladmin >/dev/null 2>&1; then
        db_admin="mysqladmin"
    fi

    if command -v mariadb >/dev/null 2>&1; then
        db_client="mariadb"
    elif command -v mysql >/dev/null 2>&1; then
        db_client="mysql"
    else
        log_error "MariaDB/MySQL client binary not found."
        exit 1
    fi

    if [[ -n "${DB_ROOT_PASS:-}" ]]; then
        local escaped_root_pass
        escaped_root_pass="${DB_ROOT_PASS//\\/\\\\}"
        escaped_root_pass="${escaped_root_pass//\"/\\\"}"
        TMP_DB_CNF="$(mktemp)"
        chmod 0600 "${TMP_DB_CNF}"
        cat > "${TMP_DB_CNF}" <<EOF
[client]
user="root"
password="${escaped_root_pass}"
EOF
    fi

    if [[ -n "${db_admin}" ]]; then
        local retries=15
        local ready=0
        while (( retries > 0 )); do
            if run_db_admin "${db_admin}" ping --silent >/dev/null 2>&1; then
                ready=1
                break
            fi
            sleep 1
            retries=$((retries - 1))
        done

        if [[ "${ready}" -ne 1 ]]; then
            log_error "MariaDB service did not become ready within timeout."
            exit 1
        fi
    fi

    local escaped_pass
    escaped_pass="${DB_PASS//\\/\\\\}"
    escaped_pass="${escaped_pass//\'/\'\'}"

    log_info "Provisioning MariaDB database '${DB_NAME}' and user '${DB_USER}'..."
    run_db_client "${db_client}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${escaped_pass}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${escaped_pass}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${escaped_pass}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
}

setup_python_venv() {
    local req_file="${PROJECT_ROOT}/requirements.txt"
    local venv_dir="${APP_DIR}/venv"

    if [[ ! -f "${req_file}" ]]; then
        log_info "No requirements.txt found; skipping Python virtualenv installation."
        return 0
    fi

    if [[ ! -d "${venv_dir}" ]]; then
        log_info "Creating Python virtual environment at '${venv_dir}'..."
        python3 -m venv "${venv_dir}"
    fi

    log_info "Installing Python dependencies from requirements.txt..."
    "${venv_dir}/bin/pip" install --no-cache-dir --upgrade pip
    "${venv_dir}/bin/pip" install --no-cache-dir -r "${req_file}"

    if id -u "${APP_USER}" >/dev/null 2>&1; then
        chown -R "${APP_USER}:${APP_GROUP}" "${venv_dir}"
    fi
}

main() {
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be run as root (e.g., sudo bash scripts/02_install_deps.sh)."
        exit 1
    fi

    load_env
    validate_required_vars
    detect_os_family
    install_packages
    configure_database
    setup_python_venv

    log_info "Dependencies and database provisioning completed successfully."
}

main "$@"
