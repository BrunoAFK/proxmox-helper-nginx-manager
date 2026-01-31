#!/usr/bin/env bash
set -euo pipefail
umask 022

# Nginx Proxy Manager - Universal Management Script
# - Supports fresh installation, updates, migration, and rollback
# - Compatible with legacy community script installations
# - Works on Debian/Ubuntu (bare metal, VM, LXC)
# - Automatic detection of installation type and migration support
#
# Author: Enhanced community version

VERSION="3.1.0"
REPO="NginxProxyManager/nginx-proxy-manager"

# ============================================================================
# CONFIGURATION - Adjust these as needed
# ============================================================================

# Version settings
NPM_VERSION_DEFAULT="2.13.5"      # Set to "latest" for auto-detection
NODE_MAJOR_DEFAULT="22"            # Node.js major version
YARN_VERSION_DEFAULT="1.22.22"    # Yarn classic version

# Paths
APP_DIR="/app"
DATA_DIR="/data"
BACKUP_DIR="/opt/npm-backups"
TMP_DIR="/tmp/npm-upgrade"
LOCK_FILE="/var/lock/npm-manager.lock"
LOG_FILE="/var/log/npm-manager.log"

# Services
SERVICE_APP="npm.service"
SERVICE_NGINX="openresty.service"

# ============================================================================
# DO NOT EDIT BELOW THIS LINE UNLESS YOU KNOW WHAT YOU'RE DOING
# ============================================================================

# Colors (terminal only)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# Flags/options
CHECK_ONLY=false
FORCE_UPDATE=false
NO_BACKUP=false
KEEP_DATA_ON_ROLLBACK=false
DEBUG=false
MIGRATE_MODE=false
TAKEOVER_NGINX=false  
AUTO_DEPS_ON_ROLLBACK=false
MANUAL_DEPS_ON_ROLLBACK=false
TARGET_VERSION="${NPM_VERSION_DEFAULT}"
NODE_MAJOR="${NODE_MAJOR_DEFAULT}"
YARN_VERSION="${YARN_VERSION_DEFAULT}"

# Installation type detection
INSTALL_TYPE=""  # community-old, community-new, or clean

# Trap for cleanup
trap 'cleanup_on_exit' EXIT INT TERM

cleanup_on_exit() {
  local exit_code=$?
  if [[ ${exit_code} -ne 0 ]]; then
    debug "Script exited with error code ${exit_code}, cleaning up..."
  fi
  rm -rf "${TMP_DIR}" 2>/dev/null || true
}

# -----------------------------
# Logging (terminal colored, file plain)
# -----------------------------
ts() { date -Is; }

log() {
  local msg="$*"
  if [[ -t 2 ]]; then
    printf "%b[%s]%b %s\n" "${GREEN}" "$(ts)" "${NC}" "${msg}" >&2
  else
    printf "[%s] %s\n" "$(ts)" "${msg}" >&2
  fi
  printf "[%s] %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

warn() {
  local msg="$*"
  if [[ -t 2 ]]; then
    printf "%b[%s] WARNING:%b %s\n" "${YELLOW}" "$(ts)" "${NC}" "${msg}" >&2
  else
    printf "[%s] WARNING: %s\n" "$(ts)" "${msg}" >&2
  fi
  printf "[%s] WARNING: %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
}

die() {
  local msg="$*"
  if [[ -t 2 ]]; then
    printf "%b[%s] ERROR:%b %s\n" "${RED}" "$(ts)" "${NC}" "${msg}" >&2
  else
    printf "[%s] ERROR: %s\n" "$(ts)" "${msg}" >&2
  fi
  printf "[%s] ERROR: %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
  exit 1
}

debug() {
  if [[ "${DEBUG}" == "true" ]]; then
    local msg="$*"
    if [[ -t 2 ]]; then
      printf "%b[%s] DEBUG:%b %s\n" "${MAGENTA}" "$(ts)" "${NC}" "${msg}" >&2
    else
      printf "[%s] DEBUG: %s\n" "$(ts)" "${msg}" >&2
    fi
    printf "[%s] DEBUG: %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}" 2>/dev/null || true
  fi
}

need_cmd() { 
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1. Please install it first."
}

# -----------------------------
# Help/version
# -----------------------------
show_help() {
  local width
  width=$(tput cols 2>/dev/null || echo 80)
  local max_width=$((width > 100 ? 100 : width))

  if [[ -t 1 ]]; then
    clear
  fi

  local header="Nginx Proxy Manager - Universal Management Tool"
  local padding=$(( (max_width - ${#header}) / 2 ))
  [[ $padding -lt 0 ]] && padding=0

  echo ""
  printf '%*s' "$max_width" | tr ' ' '═'
  echo ""
  printf '%*s' "$padding" ""
  echo -e "${BOLD}${CYAN}${header}${NC}"
  printf '%*s' "$((padding + 5))" ""
  echo -e "${DIM}Version ${VERSION}${NC}"
  printf '%*s' "$max_width" | tr ' ' '═'
  echo ""
  echo ""

  echo -e "${BOLD}${GREEN}USAGE${NC}"
  echo -e "  $(basename "$0") ${CYAN}[COMMAND]${NC} ${YELLOW}[OPTIONS]${NC}"
  echo ""

  echo -e "${BOLD}${GREEN}COMMANDS${NC}"
  echo -e "  ${CYAN}install${NC}         Fresh installation"
  echo -e "  ${CYAN}update${NC}          Update to latest/specified version"
  echo -e "  ${CYAN}migrate${NC}         Migrate from old installation (preserves data)"
  echo -e "  ${CYAN}rollback${NC}        Restore previous version from backup"
  echo -e "  ${CYAN}uninstall${NC}       Remove NPM (keeps /data by default)"
  echo -e "  ${CYAN}status${NC}          Show systemd service status"
  echo -e "  ${CYAN}logs${NC}            Follow live NPM logs"
  echo -e "  ${CYAN}nginx-logs${NC}      Follow live OpenResty logs"
  echo -e "  ${CYAN}install-log${NC}     Show installer log (last 200 lines)"
  echo -e "  ${CYAN}install-logs${NC}    Follow installer log"
  echo -e "  ${CYAN}doctor${NC}          System diagnostics and installation info"
  echo -e "  ${CYAN}--help${NC}          Show this help screen"
  echo -e "  ${CYAN}--version${NC}       Show script version"
  echo ""

  echo -e "${BOLD}${GREEN}OPTIONS${NC}"
  echo -e "  ${YELLOW}--check-only${NC}   Check for updates without installing"
  echo -e "  ${YELLOW}--force${NC}         Force reinstall even if up-to-date"
  echo -e "  ${YELLOW}--no-backup${NC}     Skip backup (faster, no rollback possible)"
  echo -e "  ${YELLOW}--keep-data${NC}     On rollback, keep current /data"
  echo -e "  ${YELLOW}--takeover-nginx${NC} Replace existing nginx/apache configuration (DANGEROUS)"
  echo -e "  ${YELLOW}--target <ver>${NC}  Install specific version (e.g., 2.13.5 or 'latest')"
  echo -e "  ${YELLOW}--node <major>${NC}  Node.js major version (default: ${NODE_MAJOR_DEFAULT})"
  echo -e "  ${YELLOW}--debug${NC}         Verbose logging for troubleshooting"
  echo ""

  echo -e "${BOLD}${GREEN}EXAMPLES${NC}"
  echo -e "  ${DIM}# Fresh installation${NC}"
  echo -e "  sudo $(basename "$0") install"
  echo ""
  echo -e "  ${DIM}# Update to latest version${NC}"
  echo -e "  sudo $(basename "$0") update"
  echo ""
  echo -e "  ${DIM}# Update to specific version${NC}"
  echo -e "  sudo $(basename "$0") update --target 2.13.5"
  echo ""
  echo -e "  ${DIM}# Migrate from old community script installation${NC}"
  echo -e "  sudo $(basename "$0") migrate"
  echo ""
  echo -e "  ${DIM}# Check for updates without installing${NC}"
  echo -e "  sudo $(basename "$0") update --check-only"
  echo ""
  echo -e "  ${DIM}# Rollback to previous version${NC}"
  echo -e "  sudo $(basename "$0") rollback"
  echo ""
  echo -e "  ${DIM}# System diagnostics${NC}"
  echo -e "  sudo $(basename "$0") doctor"
  echo ""

  echo -e "${BOLD}${GREEN}FEATURES${NC}"
  echo -e "  ${BLUE}•${NC} Automatic detection of installation type (community/clean)"
  echo -e "  ${BLUE}•${NC} Migration support from old installations"
  echo -e "  ${BLUE}•${NC} Automatic rollback on failed updates"
  echo -e "  ${BLUE}•${NC} Data preservation during updates/migrations"
  echo -e "  ${BLUE}•${NC} Dependency version management"
  echo -e "  ${BLUE}•${NC} GitHub API rate limit handling"
  echo -e "  ${BLUE}•${NC} Full logging to ${LOG_FILE}"
  echo -e "  ${BLUE}•${NC} Concurrent execution prevention"
  echo ""

  echo -e "${BOLD}${GREEN}DIRECTORY STRUCTURE${NC}"
  echo -e "  ${MAGENTA}${APP_DIR}${NC}                       Application runtime (backend + frontend)"
  echo -e "  ${MAGENTA}${DATA_DIR}${NC}                      Configuration, database & SSL certificates"
  echo -e "  ${MAGENTA}${BACKUP_DIR}/previous${NC}          Rollback backup"
  echo -e "  ${MAGENTA}${LOG_FILE}${NC}   Installer logs"
  echo ""

  echo -e "${BOLD}${GREEN}SERVICES${NC}"
  echo -e "  ${CYAN}${SERVICE_APP}${NC}                NPM backend (Node.js)"
  echo -e "  ${CYAN}${SERVICE_NGINX}${NC}          OpenResty reverse proxy"
  echo ""

  echo -e "${BOLD}${GREEN}ACCESS${NC}"
  echo -e "  After installation, access admin panel at:"
  echo -e "  ${BOLD}${CYAN}http://YOUR_SERVER_IP:81${NC}"
  echo ""
  echo -e "  Default credentials:"
  echo -e "  ${DIM}Email:${NC}    admin@example.com"
  echo -e "  ${DIM}Password:${NC} changeme"
  echo ""
  echo -e "  ${YELLOW}⚠  Change credentials immediately after first login!${NC}"
  echo ""

  echo -e "${BOLD}${GREEN}NOTES${NC}"
  echo -e "  ${DIM}•${NC} Requires root privileges"
  echo -e "  ${DIM}•${NC} Requires systemd (Debian 12+/Ubuntu 22.04+ recommended)"
  echo -e "  ${DIM}•${NC} Optional: export ${CYAN}GITHUB_TOKEN${NC} to avoid API rate limits"
  echo -e "  ${DIM}•${NC} Migration preserves all data from /data directory"
  echo ""

  printf '%*s' "$max_width" | tr ' ' '─'
  echo ""
  echo -e "${DIM}Repository: https://github.com/${REPO}${NC}"
  echo -e "${DIM}Script Version: ${VERSION}${NC}"
  printf '%*s' "$max_width" | tr ' ' '─'
  echo ""
}

show_version() {
  echo -e "${BOLD}${CYAN}NPM Universal Management Tool${NC} v${VERSION}"
  echo -e "${DIM}Repository: https://github.com/${REPO}${NC}"
}

# -----------------------------
# Preconditions/locking
# -----------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "This script must be run as root."
}

require_systemd() {
  need_cmd systemctl
  if ! systemctl --version >/dev/null 2>&1; then
    die "systemd is required but not available."
  fi
}

acquire_lock() {
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    die "Another instance is already running (lock: ${LOCK_FILE})."
  fi
}

init_logfile() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}" 2>/dev/null || true
  chmod 600 "${LOG_FILE}" 2>/dev/null || true
}

# -----------------------------
# OS detection
# -----------------------------
OS_ID=""
OS_VERSION=""
OS_CODENAME=""

detect_os() {
  [[ -f /etc/os-release ]] || die "Cannot detect OS (/etc/os-release missing)."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VERSION="${VERSION_ID:-unknown}"
  OS_CODENAME="${VERSION_CODENAME:-}"
  log "Detected OS: ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
  
  # Warn about old Debian versions
  if [[ "${OS_ID}" == "debian" && "${OS_VERSION}" =~ ^(11|10|9)$ ]]; then
    warn "Debian ${OS_VERSION} is old. Debian 12+ is recommended."
  fi
}

# -----------------------------
# Installation detection
# -----------------------------
detect_installation_type() {
  INSTALL_TYPE=""
  
  if [[ ! -f "/lib/systemd/system/${SERVICE_APP}" ]] && [[ ! -f "/etc/systemd/system/${SERVICE_APP}" ]]; then
    INSTALL_TYPE="none"
    debug "No NPM installation detected"
    return 0
  fi
  
  # Check for old community script (uses /opt/nginxproxymanager)
  if [[ -d "/opt/nginxproxymanager" ]]; then
    INSTALL_TYPE="community-new"
    debug "Detected: Community script installation (new style with /opt/nginxproxymanager)"
    return 0
  fi
  
  # Check for pnpm presence (old community script indicator)
  if command -v pnpm >/dev/null 2>&1; then
    INSTALL_TYPE="community-old"
    debug "Detected: Community script installation (old style with pnpm)"
    return 0
  fi
  
  # Check working directory in service file
  local working_dir
  working_dir=$(systemctl show -p WorkingDirectory --value "${SERVICE_APP}" 2>/dev/null || echo "")
  
  if [[ "${working_dir}" == "/app" ]] && [[ -f "${APP_DIR}/index.js" ]]; then
    # Could be this script's installation or community
    if [[ -f "${APP_DIR}/.version" ]]; then
      INSTALL_TYPE="this-script"
      debug "Detected: Installation by this script"
    else
      INSTALL_TYPE="community-new"
      debug "Detected: Community script installation"
    fi
  else
    INSTALL_TYPE="unknown"
    debug "Unknown installation type detected"
  fi
}

is_installed() {
  detect_installation_type
  [[ "${INSTALL_TYPE}" != "none" ]]
}

get_current_version() {
  # Try multiple methods to detect version
  
  # Method 1: Our .version marker
  if [[ -f "${APP_DIR}/.version" ]]; then
    tr -d '[:space:]' < "${APP_DIR}/.version" | sed 's/^v//'
    return 0
  fi
  
  # Method 2: Backend package.json
  if [[ -f "${APP_DIR}/package.json" ]]; then
    local ver
    ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${APP_DIR}/package.json" | head -n1)
    if [[ -n "${ver}" && "${ver}" != "0.0.0" && "${ver}" != "2.0.0" ]]; then
      echo "${ver}"
      return 0
    fi
  fi
  
  # Method 3: /opt/nginxproxymanager (community new)
  if [[ -f "/opt/nginxproxymanager/backend/package.json" ]]; then
    local ver
    ver=$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "/opt/nginxproxymanager/backend/package.json" | head -n1)
    if [[ -n "${ver}" && "${ver}" != "0.0.0" && "${ver}" != "2.0.0" ]]; then
      echo "${ver}"
      return 0
    fi
  fi
  
  echo ""
}

get_latest_tag_version() {
  local json tag
  local cache_bust="?t=$(date +%s)"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    json="$(curl -fsSL --retry 3 --retry-delay 1 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: npm-manager" \
      -H "Cache-Control: no-cache" \
      -H "Pragma: no-cache" \
      "https://api.github.com/repos/${REPO}/tags${cache_bust}")" || return 1
  else
    json="$(curl -fsSL --retry 3 --retry-delay 1 \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: npm-manager" \
      -H "Cache-Control: no-cache" \
      -H "Pragma: no-cache" \
      "https://api.github.com/repos/${REPO}/tags${cache_bust}")" || return 1
  fi

  # Pick the first semver-ish tag in the list
  tag="$(printf '%s' "$json" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\(v\{0,1\}[0-9]\+\.[0-9]\+\.[0-9]\+\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || return 1
  printf "%s\n" "${tag#v}"
}

get_latest_version() {
  local json tag latest_release latest_tag
  local cache_bust="?t=$(date +%s)"

  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    json="$(curl -fsSL --retry 3 --retry-delay 1 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: npm-manager" \
      -H "Cache-Control: no-cache" \
      -H "Pragma: no-cache" \
      "https://api.github.com/repos/${REPO}/releases/latest${cache_bust}")" || die "Could not fetch latest release from GitHub API."
  else
    json="$(curl -fsSL --retry 3 --retry-delay 1 \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: npm-manager" \
      -H "Cache-Control: no-cache" \
      -H "Pragma: no-cache" \
      "https://api.github.com/repos/${REPO}/releases/latest${cache_bust}")" || die "Could not fetch latest release from GitHub API."
  fi

  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || die "Could not parse tag_name from GitHub JSON."
  latest_release="${tag#v}"

  # Fallback to tags if releases/latest appears stale
  latest_tag="$(get_latest_tag_version || echo "")"
  if [[ -n "${latest_tag}" ]] && ver_ge "${latest_tag}" "${latest_release}" && [[ "${latest_tag}" != "${latest_release}" ]]; then
    warn "GitHub releases/latest returned ${latest_release}, but latest tag is ${latest_tag}. Using latest tag."
    printf "%s\n" "${latest_tag}"
    return 0
  fi

  printf "%s\n" "${latest_release}"
}

ver_ge() {
  # Compare versions: returns 0 if $1 >= $2
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# -----------------------------
# Dependency management
# -----------------------------
ensure_node() {
  need_cmd curl
  
  case "${OS_ID}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq

      local need_install=false
      if ! command -v node >/dev/null 2>&1; then
        need_install=true
        log "Node.js not found, installing v${NODE_MAJOR}..."
      else
        local cur_major
        cur_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
        if [[ "${cur_major}" -lt "${NODE_MAJOR}" ]]; then
          warn "Node.js v$(node -v 2>/dev/null || echo unknown) found, but v${NODE_MAJOR}+ required."
          log "Upgrading Node.js to v${NODE_MAJOR}..."
          need_install=true
        else
          log "Node.js v$(node -v) is compatible (required: v${NODE_MAJOR}+)"
        fi
      fi

      if [[ "${need_install}" == "true" ]]; then
        apt-get install -y -qq ca-certificates curl gnupg >/dev/null
        
        # Remove old NodeSource setup if exists
        rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
        rm -f /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true
        
        log "Setting up NodeSource repository for Node.js ${NODE_MAJOR}..."
        if ! curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1; then
          warn "NodeSource setup had warnings, attempting to continue..."
        fi
        
        apt-get install -y -qq nodejs >/dev/null || die "Failed to install Node.js"
        log "Node.js $(node -v) installed successfully"
      fi
      ;;
    *)
      die "Unsupported OS for automatic Node.js installation: ${OS_ID}"
      ;;
  esac
}

ensure_yarn() {
  # Prefer corepack if available (Node 16+)
  if command -v corepack >/dev/null 2>&1; then
    debug "Enabling corepack for yarn management"
    corepack enable >/dev/null 2>&1 || true
    corepack prepare "yarn@${YARN_VERSION}" --activate >/dev/null 2>&1 || true
  fi
  
  if ! command -v yarn >/dev/null 2>&1; then
    log "Installing yarn@${YARN_VERSION}..."
    npm install -g "yarn@${YARN_VERSION}" >/dev/null || die "Failed to install yarn"
  fi
  
  local yarn_ver
  yarn_ver=$(yarn -v 2>/dev/null || echo "unknown")
  log "Yarn version: ${yarn_ver}"
}

ensure_build_deps() {
  case "${OS_ID}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      log "Installing build dependencies..."
      apt-get update -qq
      apt-get install -y -qq \
        ca-certificates \
        curl \
        wget \
        git \
        tar \
        gzip \
        build-essential \
        python3 \
        python3-venv \
        python3-pip \
        python3-dev \
        python3-cffi \
        openssl \
        logrotate \
        apache2-utils >/dev/null || die "Failed to install build dependencies"
      ;;
    *)
      die "Unsupported OS for dependencies: ${OS_ID}"
      ;;
  esac
}

ensure_openresty() {
  if command -v openresty >/dev/null 2>&1; then
    log "OpenResty already installed: $(openresty -v 2>&1 | head -n1)"
    return 0
  fi

  case "${OS_ID}" in
    debian|ubuntu)
      log "Installing OpenResty..."
      apt-get install -y -qq gnupg >/dev/null

      # Remove old repo format
      rm -f /etc/apt/sources.list.d/openresty.list 2>/dev/null || true
      rm -f /etc/apt/trusted.gpg.d/openresty-archive-keyring.gpg 2>/dev/null || true

      # Add OpenResty GPG key
      if [[ ! -f /etc/apt/trusted.gpg.d/openresty.gpg ]]; then
        curl -fsSL "https://openresty.org/package/pubkey.gpg" | \
          gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/openresty.gpg || \
          die "Failed to add OpenResty GPG key"
      fi

      # Determine suite
      local suite="${OS_CODENAME:-bookworm}"
      if [[ -z "${suite}" ]]; then 
        suite="bookworm"
      fi
      
      # Handle Ubuntu codenames
      if [[ "${OS_ID}" == "ubuntu" ]]; then
        case "${OS_CODENAME}" in
          jammy) suite="jammy" ;;
          focal) suite="focal" ;;
          *) suite="jammy" ;;  # Default to jammy for unknown Ubuntu versions
        esac
      fi

      # Create sources file in DEB822 format
      cat <<EOF >/etc/apt/sources.list.d/openresty.sources
Types: deb
URIs: http://openresty.org/package/${OS_ID}/
Suites: ${suite}
Components: openresty
Signed-By: /etc/apt/trusted.gpg.d/openresty.gpg
EOF

      apt-get update -qq || die "Failed to update package lists"
      apt-get install -y -qq openresty >/dev/null || die "Failed to install OpenResty"
      log "OpenResty installed successfully"
      ;;
    *)
      die "OpenResty installation not supported on: ${OS_ID}"
      ;;
  esac
}

ensure_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    log "certbot already installed: $(certbot --version 2>&1 | head -n1)"
    return 0
  fi
  
  log "Setting up certbot in Python virtual environment..."
  python3 -m venv /opt/certbot || die "Failed to create certbot venv"
  /opt/certbot/bin/pip install --upgrade pip setuptools wheel >/dev/null 2>&1 || true
  /opt/certbot/bin/pip install certbot certbot-dns-cloudflare >/dev/null || die "Failed to install certbot"
  ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
  log "certbot installed successfully"
}

install_dependencies() {
  log "Installing system dependencies..."
  ensure_build_deps
  ensure_node
  ensure_yarn
  ensure_certbot
  ensure_openresty
  log "All dependencies installed successfully"
}

# -----------------------------
# Backup/rollback
# -----------------------------
backup_current_version() {
  if ! is_installed; then
    debug "No existing installation to backup"
    return 0
  fi
  
  if [[ "${NO_BACKUP}" == "true" ]]; then
    warn "Backup disabled (--no-backup). Rollback will not be possible."
    return 0
  fi

  mkdir -p "${BACKUP_DIR}"
  rm -rf "${BACKUP_DIR}/previous"
  mkdir -p "${BACKUP_DIR}/previous"

  local cur
  cur="$(get_current_version)"
  log "Backing up current version (${cur:-unknown})..."

  # Create metadata file with all important versions
  cat > "${BACKUP_DIR}/previous/.metadata.json" <<EOF
{
  "npm_version": "${cur:-unknown}",
  "node_version": "$(node -v 2>/dev/null || echo unknown)",
  "yarn_version": "$(yarn -v 2>/dev/null || echo unknown)",
  "openresty_version": "$(openresty -v 2>&1 | head -n1 || echo unknown)",
  "certbot_version": "$(certbot --version 2>&1 | head -n1 || echo unknown)",
  "backup_timestamp": "$(date -Iseconds)",
  "os_id": "${OS_ID}",
  "os_version": "${OS_VERSION}",
  "install_type": "${INSTALL_TYPE}"
}
EOF

  # Backup application runtime
  if [[ -d "${APP_DIR}" ]]; then
    mkdir -p "${BACKUP_DIR}/previous${APP_DIR}"
    cp -a "${APP_DIR}" "${BACKUP_DIR}/previous$(dirname "${APP_DIR}")/" 2>/dev/null || true
  fi
  
  # Backup /opt/nginxproxymanager if exists (community script)
  if [[ -d "/opt/nginxproxymanager" ]]; then
    mkdir -p "${BACKUP_DIR}/previous/opt"
    cp -a "/opt/nginxproxymanager" "${BACKUP_DIR}/previous/opt/" 2>/dev/null || true
  fi

  # Backup configuration
  for p in \
    "/etc/nginx" \
    "/var/www/html" \
    "/etc/logrotate.d/nginx-proxy-manager" \
    "/etc/letsencrypt.ini"
  do
    if [[ -e "${p}" ]]; then
      mkdir -p "${BACKUP_DIR}/previous$(dirname "${p}")"
      cp -a "${p}" "${BACKUP_DIR}/previous${p}" 2>/dev/null || true
    fi
  done

  # Backup systemd units
  for unit_path in \
    "/lib/systemd/system/${SERVICE_APP}" \
    "/etc/systemd/system/${SERVICE_APP}"
  do
    if [[ -f "${unit_path}" ]]; then
      mkdir -p "${BACKUP_DIR}/previous$(dirname "${unit_path}")"
      cp -a "${unit_path}" "${BACKUP_DIR}/previous${unit_path}" 2>/dev/null || true
    fi
  done

  # Backup data directory
  if [[ -d "${DATA_DIR}" ]]; then
    mkdir -p "${BACKUP_DIR}/previous/data-parent"
    cp -a "${DATA_DIR}" "${BACKUP_DIR}/previous/data-parent/" 2>/dev/null || true
  fi

  # Save version info (legacy support)
  echo "${cur:-unknown}" > "${BACKUP_DIR}/previous/.version"
  echo "${INSTALL_TYPE}" > "${BACKUP_DIR}/previous/.install_type"
  
  log "Backup complete (stored in ${BACKUP_DIR}/previous)"
  log "Metadata saved: Node $(node -v 2>/dev/null || echo unknown), Yarn $(yarn -v 2>/dev/null || echo unknown)"
}

prompt_dependency_rollback_choice() {
  local backed_node_ver="$1"
  local backed_yarn_ver="$2"
  local current_node_ver="$3"

  warn "Node.js version mismatch detected!"
  warn "Backup was created with: ${backed_node_ver}"
  warn "Current version: ${current_node_ver}"
  warn ""

  # If no TTY, default to manual (continue without changing deps)
  if [[ ! -t 0 ]]; then
    warn "Non-interactive session: defaulting to MANUAL dependency rollback."
    MANUAL_DEPS_ON_ROLLBACK=true
    return 0
  fi

  echo ""
  echo "Dependency rollback options:"
  echo "  [A] Automatic: downgrade Node.js and reinstall Yarn to match backup metadata"
  echo "  [M] Manual: show instructions, continue rollback without changing Node/Yarn"
  echo "  [C] Cancel: abort rollback (no changes applied)"
  echo ""

  while true; do
    read -p "Choose (A/M/C): " -r choice
    case "${choice}" in
      A|a)
        AUTO_DEPS_ON_ROLLBACK=true
        return 0
        ;;
      M|m)
        MANUAL_DEPS_ON_ROLLBACK=true
        return 0
        ;;
      C|c)
        log "Rollback cancelled by user (no changes applied)."
        exit 0
        ;;
      *)
        echo "Invalid choice. Enter A, M, or C."
        ;;
    esac
  done
}

rollback_dependencies_auto() {
  local backed_node_ver="$1"   # example: v16.20.2
  local backed_yarn_ver="$2"   # example: 1.22.22

  if [[ -z "${backed_node_ver}" || "${backed_node_ver}" == "unknown" ]]; then
    warn "Backup metadata has no Node.js version. Skipping automatic dependency rollback."
    return 0
  fi

  # Parse major from vX.Y.Z
  local backed_node_major
  backed_node_major="$(echo "${backed_node_ver}" | tr -d '[:space:]' | sed 's/^v//' | cut -d'.' -f1)"
  if [[ -z "${backed_node_major}" || ! "${backed_node_major}" =~ ^[0-9]+$ ]]; then
    warn "Could not parse Node.js major from '${backed_node_ver}'. Skipping automatic dependency rollback."
    return 0
  fi

  log "Automatic dependency rollback selected."
  log "Rolling back Node.js to major v${backed_node_major} (from backup ${backed_node_ver})..."

  case "${OS_ID}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq

      # Remove current Node.js
      apt-get purge -y -qq nodejs npm >/dev/null 2>&1 || true
      apt-get autoremove -y -qq >/dev/null 2>&1 || true

      # Install requested Node major via NodeSource
      apt-get install -y -qq ca-certificates curl gnupg >/dev/null
      rm -f /etc/apt/sources.list.d/nodesource.list 2>/dev/null || true
      rm -f /etc/apt/keyrings/nodesource.gpg 2>/dev/null || true

      if ! curl -fsSL "https://deb.nodesource.com/setup_${backed_node_major}.x" | bash - >/dev/null 2>&1; then
        die "NodeSource setup failed for Node.js ${backed_node_major}.x"
      fi

      apt-get install -y -qq nodejs >/dev/null || die "Failed to install Node.js ${backed_node_major}.x"

      log "Node.js now: $(node -v 2>/dev/null || echo unknown)"
      ;;
    *)
      warn "Unsupported OS for automatic Node.js rollback: ${OS_ID}"
      return 1
      ;;
  esac

  # Reinstall Yarn to backed version if available
  if [[ -n "${backed_yarn_ver}" && "${backed_yarn_ver}" != "unknown" ]]; then
    log "Reinstalling Yarn ${backed_yarn_ver} to match backup..."
    if command -v corepack >/dev/null 2>&1; then
      corepack enable >/dev/null 2>&1 || true
      corepack prepare "yarn@${backed_yarn_ver}" --activate >/dev/null 2>&1 || true
    fi
    # Ensure yarn exists at requested version
    if ! command -v yarn >/dev/null 2>&1 || [[ "$(yarn -v 2>/dev/null || echo "")" != "${backed_yarn_ver}" ]]; then
      npm install -g "yarn@${backed_yarn_ver}" >/dev/null || die "Failed to install yarn@${backed_yarn_ver}"
    fi
    log "Yarn now: $(yarn -v 2>/dev/null || echo unknown)"
  else
    warn "Backup metadata has no Yarn version. Skipping Yarn reinstall."
  fi

  log "Automatic dependency rollback complete."
  return 0
}


rollback_version() {
  if [[ ! -d "${BACKUP_DIR}/previous" ]]; then
    die "No backup found to rollback to! (${BACKUP_DIR}/previous does not exist)"
  fi

  local prev
  prev="$(cat "${BACKUP_DIR}/previous/.version" 2>/dev/null || echo unknown)"

  # Read metadata if available
  local metadata_file="${BACKUP_DIR}/previous/.metadata.json"
  local backed_node_ver=""
  local backed_yarn_ver=""

  # Decide dependency rollback strategy BEFORE making changes
  if [[ -f "${metadata_file}" ]]; then
    log "Found backup metadata, checking dependency versions..."
    backed_node_ver=$(grep '"node_version"' "${metadata_file}" | cut -d'"' -f4 || echo "")
    backed_yarn_ver=$(grep '"yarn_version"' "${metadata_file}" | cut -d'"' -f4 || echo "")
    debug "Backup was created with Node ${backed_node_ver}, Yarn ${backed_yarn_ver}"

    if [[ -n "${backed_node_ver}" && "${backed_node_ver}" != "unknown" ]]; then
      local current_node_ver
      current_node_ver=$(node -v 2>/dev/null || echo "unknown")
      if [[ "${current_node_ver}" != "unknown" && "${backed_node_ver}" != "${current_node_ver}" ]]; then
        prompt_dependency_rollback_choice "${backed_node_ver}" "${backed_yarn_ver}" "${current_node_ver}"
      fi
    fi
  fi

  log "Rolling back to previous version (${prev})..."

  systemctl stop "${SERVICE_APP}" 2>/dev/null || true
  systemctl stop "${SERVICE_NGINX}" 2>/dev/null || true

  # Restore application runtime
  if [[ -d "${BACKUP_DIR}/previous${APP_DIR}" ]]; then
    rm -rf "${APP_DIR}"
    mkdir -p "$(dirname "${APP_DIR}")"
    cp -a "${BACKUP_DIR}/previous${APP_DIR}" "${APP_DIR}"
  fi

  # Restore /opt/nginxproxymanager if backed up
  if [[ -d "${BACKUP_DIR}/previous/opt/nginxproxymanager" ]]; then
    rm -rf "/opt/nginxproxymanager"
    cp -a "${BACKUP_DIR}/previous/opt/nginxproxymanager" "/opt/nginxproxymanager"
  fi

  # Restore configuration
  for p in \
    "/etc/nginx" \
    "/var/www/html" \
    "/etc/logrotate.d/nginx-proxy-manager" \
    "/etc/letsencrypt.ini"
  do
    if [[ -e "${BACKUP_DIR}/previous${p}" ]]; then
      rm -rf "${p}"
      mkdir -p "$(dirname "${p}")"
      cp -a "${BACKUP_DIR}/previous${p}" "${p}"
    fi
  done

  # Restore systemd units
  for unit_path in \
    "/lib/systemd/system/${SERVICE_APP}" \
    "/etc/systemd/system/${SERVICE_APP}"
  do
    if [[ -f "${BACKUP_DIR}/previous${unit_path}" ]]; then
      cp -a "${BACKUP_DIR}/previous${unit_path}" "${unit_path}"
    fi
  done

  # Restore data directory (unless --keep-data specified)
  if [[ "${KEEP_DATA_ON_ROLLBACK}" != "true" ]]; then
    if [[ -d "${BACKUP_DIR}/previous/data-parent${DATA_DIR}" ]]; then
      rm -rf "${DATA_DIR}"
      cp -a "${BACKUP_DIR}/previous/data-parent${DATA_DIR}" "${DATA_DIR}"
    fi
  else
    warn "Keeping current ${DATA_DIR} (--keep-data specified)"
  fi

  # Apply dependency rollback choice after files are restored, before services start
  if [[ "${AUTO_DEPS_ON_ROLLBACK}" == "true" ]]; then
    rollback_dependencies_auto "${backed_node_ver}" "${backed_yarn_ver}" || \
      warn "Automatic dependency rollback failed. Continuing rollback anyway."
  elif [[ "${MANUAL_DEPS_ON_ROLLBACK}" == "true" ]]; then
    warn "Manual dependency rollback selected. Continuing rollback without changing Node/Yarn."
    warn "If you want to match backup Node version (${backed_node_ver}), do it manually, then restart services:"
    warn "  1) apt-get purge -y nodejs npm"
    warn "  2) curl -fsSL https://deb.nodesource.com/setup_${backed_node_ver#v%%.*}.x | bash -"
    warn "  3) apt-get install -y nodejs"
    warn "  4) npm install -g yarn@${backed_yarn_ver}"
  fi

  systemctl daemon-reload 2>/dev/null || true
  systemctl start "${SERVICE_NGINX}" 2>/dev/null || true
  sleep 2
  systemctl start "${SERVICE_APP}" 2>/dev/null || true

  if healthcheck; then
    log "Rollback health check passed"
  else
    warn "Rollback completed but health check failed"
  fi

  log "Rollback complete! Restored to version ${prev}"

  if [[ -n "${backed_node_ver}" ]] && [[ "${backed_node_ver}" != "$(node -v 2>/dev/null)" ]]; then
    warn "Remember: Node.js version was not rolled back automatically"
  fi

  return 0
}


# -----------------------------
# Download/build/deploy
# -----------------------------
download_release_tree() {
  local ver="$1"
  rm -rf "${TMP_DIR}"
  mkdir -p "${TMP_DIR}"
  cd "${TMP_DIR}"

  local url="https://codeload.github.com/${REPO}/tar.gz/v${ver}"
  log "Downloading NPM v${ver} from GitHub..."
  
  if ! curl -fsSL --retry 3 --retry-delay 1 "${url}" -o release.tgz; then
    die "Failed to download release v${ver}"
  fi
  
  log "Extracting release archive..."
  tar -xzf release.tgz || die "Failed to extract release archive"

  local extracted="nginx-proxy-manager-${ver}"
  if [[ ! -d "${extracted}" ]]; then
    extracted="$(find . -maxdepth 1 -type d -name "nginx-proxy-manager-*" | head -n1)"
  fi
  [[ -n "${extracted}" && -d "${extracted}" ]] || die "Could not find extracted directory."

  printf "%s\n" "${TMP_DIR}/${extracted}"
}

patch_source_tree() {
  local tree="$1"
  local ver="$2"

  debug "Patching source tree for version ${ver}..."

  # Patch version in package.json files (handle 0.0.0, 2.0.0, or other placeholders)
  for pkg in "${tree}/backend/package.json" "${tree}/frontend/package.json"; do
    if [[ -f "${pkg}" ]]; then
      sed -i -E "s/\"version\"[[:space:]]*:[[:space:]]*\"(0\.0\.0|2\.0\.0|[0-9]+\.[0-9]+\.[0-9]+)\"/\"version\": \"${ver}\"/g" "${pkg}" || true
    fi
  done

  # Comment out daemon directive in nginx.conf
  if [[ -f "${tree}/docker/rootfs/etc/nginx/nginx.conf" ]]; then
    sed -i 's+^daemon+#daemon+g' "${tree}/docker/rootfs/etc/nginx/nginx.conf" || true
  fi

  # Fix include paths in nginx config files
  while IFS= read -r -d '' conf; do
    sed -i 's+include conf.d+include /etc/nginx/conf.d+g' "${conf}" || true
  done < <(find "${tree}" -type f -name "*.conf" -print0 2>/dev/null || true)

  # Replace node-sass with sass in frontend package.json
  if [[ -f "${tree}/frontend/package.json" ]]; then
    if grep -q '"node-sass"' "${tree}/frontend/package.json"; then
      log "Replacing node-sass with sass in frontend package.json..."
      sed -i -E 's/"node-sass"[[:space:]]*:[[:space:]]*"[^"]*"/"sass": "^1.92.1"/g' "${tree}/frontend/package.json" || true
    fi
  fi
  
  debug "Source tree patching complete"
}

build_frontend() {
  local tree="$1"

  log "Building frontend (this may take several minutes)..."
  export NODE_OPTIONS="--max_old_space_size=2048 --openssl-legacy-provider"
  
  if [[ ! -d "${tree}/frontend" ]]; then
    die "Frontend directory not found: ${tree}/frontend"
  fi
  
  cd "${tree}/frontend"

  log "Installing frontend dependencies..."
  yarn install --network-timeout 600000 || die "Frontend dependency installation failed"

  # Compile locales if script exists
  if grep -q '"locale-compile"' package.json 2>/dev/null; then
    log "Compiling locales..."
    yarn locale-compile || warn "Locale compilation failed, continuing..."
  fi

  log "Running frontend build..."
  yarn build || die "Frontend build failed"
  
  log "Frontend build complete"
}

deploy_environment_files() {
  local tree="$1"

  log "Deploying environment files and configuration..."
  
  # Check if nginx/web services already exist
  if [[ "${TAKEOVER_NGINX}" != "true" ]]; then
    local nginx_exists=false
    
    # Check for existing nginx installations
    if [[ -d /etc/nginx ]] && [[ ! -L /etc/nginx ]]; then
      if [[ -f /etc/nginx/nginx.conf ]] && ! grep -q "openresty" /etc/nginx/nginx.conf 2>/dev/null; then
        nginx_exists=true
      fi
    fi
    
    # Check for apache
    if systemctl is-active --quiet apache2 2>/dev/null; then
      nginx_exists=true
    fi
    
    # Check for other nginx
    if systemctl is-active --quiet nginx 2>/dev/null && ! systemctl is-active --quiet openresty 2>/dev/null; then
      nginx_exists=true
    fi
    
    if [[ "${nginx_exists}" == "true" ]]; then
      warn "════════════════════════════════════════════════════════════"
      warn "  EXISTING WEB SERVER DETECTED"
      warn "════════════════════════════════════════════════════════════"
      warn ""
      warn "This script will REPLACE your existing nginx/apache configuration!"
      warn "This includes:"
      warn "  - /etc/nginx (will be deleted and replaced)"
      warn "  - /var/www/html (will be deleted)"
      warn "  - Any existing virtual hosts or configurations"
      warn ""
      warn "This is designed for DEDICATED NPM servers only."
      warn ""
      warn "Options:"
      warn "  1. Cancel now and backup your configs manually"
      warn "  2. Run with --takeover-nginx flag to proceed anyway"
      warn "  3. Use a fresh/dedicated server for NPM"
      warn ""
      die "Existing web server detected. Aborting for safety. Use --takeover-nginx to override."
    fi
  else
    warn "NGINX TAKEOVER MODE: Will replace existing web server configuration"
  fi

  # Create symlinks
  ln -sf /usr/bin/python3 /usr/bin/python 2>/dev/null || true
  ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx 2>/dev/null || true
  ln -sf /usr/local/openresty/nginx/ /etc/nginx 2>/dev/null || true

  # Clean old files
  rm -rf \
    /var/www/html \
    /etc/nginx \
    /var/log/nginx \
    /var/lib/nginx \
    /var/cache/nginx 2>/dev/null || true

  # Create directory structure
  mkdir -p /var/www/html /etc/nginx/logs

  # Copy environment files from docker rootfs
  if [[ -d "${tree}/docker/rootfs/var/www/html" ]]; then
    cp -r "${tree}/docker/rootfs/var/www/html/"* /var/www/html/ || true
  fi
  
  if [[ -d "${tree}/docker/rootfs/etc/nginx" ]]; then
    cp -r "${tree}/docker/rootfs/etc/nginx/"* /etc/nginx/ || true
  fi
  
  if [[ -f "${tree}/docker/rootfs/etc/letsencrypt.ini" ]]; then
    cp "${tree}/docker/rootfs/etc/letsencrypt.ini" /etc/letsencrypt.ini || true
  fi
  
  if [[ -f "${tree}/docker/rootfs/etc/logrotate.d/nginx-proxy-manager" ]]; then
    cp "${tree}/docker/rootfs/etc/logrotate.d/nginx-proxy-manager" /etc/logrotate.d/nginx-proxy-manager || true
  fi

  # Additional nginx config
  ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf 2>/dev/null || true
  rm -f /etc/nginx/conf.d/dev.conf 2>/dev/null || true

  # Create required runtime directories
  mkdir -p \
    /tmp/nginx/body \
    /run/nginx \
    /data/nginx \
    /data/custom_ssl \
    /data/logs \
    /data/access \
    /data/nginx/default_host \
    /data/nginx/default_www \
    /data/nginx/proxy_host \
    /data/nginx/redirection_host \
    /data/nginx/stream \
    /data/nginx/dead_host \
    /data/nginx/temp \
    /var/lib/nginx/cache/public \
    /var/lib/nginx/cache/private \
    /var/cache/nginx/proxy_temp

  # Set permissions (more secure than 777)
  chmod -R 755 /var/cache/nginx 2>/dev/null || true
  chown -R root:root /var/cache/nginx 2>/dev/null || true
  chown root:root /tmp/nginx 2>/dev/null || true
  chmod 755 /tmp/nginx 2>/dev/null || true

  # Configure resolvers
  mkdir -p /etc/nginx/conf.d/include 2>/dev/null || true
  if [[ -f /etc/resolv.conf ]]; then
    echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf);" \
      > /etc/nginx/conf.d/include/resolvers.conf
  fi

  # Generate dummy SSL certificate if needed
  if [[ ! -f /data/nginx/dummycert.pem || ! -f /data/nginx/dummykey.pem ]]; then
    log "Generating dummy SSL certificate..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" \
      -keyout /data/nginx/dummykey.pem \
      -out /data/nginx/dummycert.pem >/dev/null 2>&1 || \
      warn "Failed to generate dummy certificate"
  fi
  
  log "Environment files deployed"
}

deploy_runtime_app() {
  local tree="$1"
  local ver="$2"

  log "Deploying application runtime to ${APP_DIR}..."
  
  # Clean and recreate app directory
  rm -rf "${APP_DIR}"
  mkdir -p "${APP_DIR}" /app/frontend/images /app/global

  # Copy backend runtime files
  if [[ ! -d "${tree}/backend" ]]; then
    die "Backend directory not found: ${tree}/backend"
  fi
  cp -r "${tree}/backend/"* "${APP_DIR}/"

  # Copy global files if they exist
  if [[ -d "${tree}/global" ]]; then
    cp -r "${tree}/global/"* /app/global/ 2>/dev/null || true
  fi

  # Copy built frontend artifacts
  if [[ -d "${tree}/frontend/dist" ]]; then
    cp -r "${tree}/frontend/dist/"* /app/frontend/
  else
    warn "Frontend dist directory not found, frontend may not work"
  fi

  # Copy frontend images (try multiple possible locations)
  if [[ -d "${tree}/frontend/app-images" ]]; then
    cp -r "${tree}/frontend/app-images/"* /app/frontend/images/ 2>/dev/null || true
  elif [[ -d "${tree}/frontend/public/images" ]]; then
    cp -r "${tree}/frontend/public/images/"* /app/frontend/images/ 2>/dev/null || true
  fi

  # Write version marker
  echo "${ver}" > "${APP_DIR}/.version"

  # Configure backend
  log "Configuring backend..."
  rm -rf /app/config/default.json 2>/dev/null || true

  if [[ ! -f /app/config/production.json ]]; then
    mkdir -p /app/config
    cat <<'EOF' >/app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
  fi

  # Install backend dependencies
  log "Installing backend dependencies..."
  cd /app
  export NODE_OPTIONS="--openssl-legacy-provider"
  yarn install --network-timeout 600000 || die "Backend dependency installation failed"
  
  log "Application runtime deployed successfully"
}

create_service() {
  if [[ -f "/lib/systemd/system/${SERVICE_APP}" ]]; then
    debug "Service ${SERVICE_APP} already exists, skipping creation"
    return 0
  fi

  log "Creating systemd service ${SERVICE_APP}..."
  cat <<'EOF' >/lib/systemd/system/npm.service
[Unit]
Description=Nginx Proxy Manager
After=network.target
Wants=openresty.service

[Service]
Type=simple
Environment=NODE_ENV=production
ExecStartPre=-mkdir -p /tmp/nginx/body /data/letsencrypt-acme-challenge
ExecStart=/usr/bin/node index.js --abort_on_uncaught_exception --max_old_space_size=250
WorkingDirectory=/app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable -q npm.service
  log "Service created and enabled"
}

configure_services() {
  log "Configuring services for production use..."
  
  # Configure OpenResty to run as root (required for port 80/443)
  sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf 2>/dev/null || true
  
  # Fix logrotate to avoid su errors
  if [[ -f /etc/logrotate.d/nginx-proxy-manager ]]; then
    sed -r -i 's/^([[:space:]]*)su npm npm/\1#su npm npm/g;' /etc/logrotate.d/nginx-proxy-manager 2>/dev/null || true
  fi
}

start_services() {
  log "Starting services..."
  
  systemctl enable -q --now "${SERVICE_NGINX}" 2>/dev/null || true
  systemctl enable -q --now "${SERVICE_APP}" 2>/dev/null || true
  
  systemctl restart "${SERVICE_NGINX}" 2>/dev/null || true
  sleep 2
  systemctl restart "${SERVICE_APP}" 2>/dev/null || true
  
  sleep 3
}

stop_services() {
  log "Stopping services..."
  systemctl stop "${SERVICE_APP}" 2>/dev/null || true
  systemctl stop "${SERVICE_NGINX}" 2>/dev/null || true
  sleep 1
}

healthcheck() {
  log "Running health check..."
  local retries=15
  local i=0
  local healthy=false

  while [[ $i -lt $retries ]]; do
    if systemctl is-active --quiet "${SERVICE_APP}" && systemctl is-active --quiet "${SERVICE_NGINX}"; then
      if curl -fsS "http://127.0.0.1:81" >/dev/null 2>&1 || curl -fsS "http://localhost:81" >/dev/null 2>&1; then
        healthy=true
        break
      fi
    fi
    i=$((i+1))
    sleep 2
  done

  if [[ "${healthy}" == "true" ]]; then
    log "✓ Health check passed - services are running and responding"
    return 0
  else
    warn "Health check failed - services may not be responding correctly"
    log "Service status:"
    systemctl status "${SERVICE_APP}" --no-pager -n 20 2>&1 || true
    systemctl status "${SERVICE_NGINX}" --no-pager -n 20 2>&1 || true
    return 1
  fi
}

# -----------------------------
# Migration support
# -----------------------------
migrate_from_old_installation() {
  log "════════════════════════════════════════════════════════════"
  log "  MIGRATION MODE - Preserving existing data"
  log "════════════════════════════════════════════════════════════"
  
  detect_installation_type
  
  if [[ "${INSTALL_TYPE}" == "none" ]]; then
    die "No existing installation detected. Use 'install' command for fresh installation."
  fi
  
  local current_ver
  current_ver=$(get_current_version)
  log "Current installation: ${INSTALL_TYPE} (version: ${current_ver:-unknown})"
  
  # Backup existing data
  log "Backing up existing installation..."
  backup_current_version
  
  # Determine target version
  local target_ver
  if [[ "${TARGET_VERSION}" == "latest" ]]; then
    target_ver=$(get_latest_version)
  else
    target_ver="${TARGET_VERSION}"
  fi
  
  log "Target version: ${target_ver}"
  
  # Install dependencies
  install_dependencies
  
  # Download and prepare new version
  local tree
  tree="$(download_release_tree "${target_ver}")"
  patch_source_tree "${tree}" "${target_ver}"
  build_frontend "${tree}"
  
  # Stop services
  stop_services
  
  # Deploy new version (data is preserved)
  deploy_environment_files "${tree}"
  deploy_runtime_app "${tree}" "${target_ver}"
  create_service
  configure_services
  start_services
  
  if healthcheck; then
    log "════════════════════════════════════════════════════════════"
    log "  ✓ Migration successful!"
    log "════════════════════════════════════════════════════════════"
    log "Migrated from: ${current_ver:-unknown} (${INSTALL_TYPE})"
    log "Current version: ${target_ver}"
    log "Data preserved in: ${DATA_DIR}"
  else
    warn "Migration completed but health check failed. Rolling back..."
    rollback_version || die "Rollback failed after failed migration"
    die "Migration failed and was rolled back"
  fi
}

# -----------------------------
# Uninstall
# -----------------------------
uninstall_npm() {
  log "════════════════════════════════════════════════════════════"
  log "  UNINSTALL - Removing Nginx Proxy Manager"
  log "════════════════════════════════════════════════════════════"
  
  if ! is_installed; then
    warn "No NPM installation detected"
    return 0
  fi
  
  # Confirm with user
  echo -e "${YELLOW}This will remove NPM but keep your data in ${DATA_DIR}${NC}"
  echo -e "${YELLOW}To remove data too, manually delete ${DATA_DIR} after uninstall${NC}"
  read -p "Continue? (yes/no): " -r
  if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
    log "Uninstall cancelled"
    return 0
  fi
  
  # Stop services
  stop_services
  
  # Disable services
  systemctl disable "${SERVICE_APP}" 2>/dev/null || true
  systemctl disable "${SERVICE_NGINX}" 2>/dev/null || true
  
  # Remove service files
  rm -f "/lib/systemd/system/${SERVICE_APP}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE_APP}" 2>/dev/null || true
  systemctl daemon-reload
  
  # Remove application
  rm -rf "${APP_DIR}" 2>/dev/null || true
  rm -rf "/opt/nginxproxymanager" 2>/dev/null || true
  
  # Remove configuration
  rm -rf /etc/nginx 2>/dev/null || true
  rm -rf /var/www/html 2>/dev/null || true
  rm -f /etc/letsencrypt.ini 2>/dev/null || true
  rm -f /etc/logrotate.d/nginx-proxy-manager 2>/dev/null || true
  
  # Remove cache
  rm -rf /var/cache/nginx 2>/dev/null || true
  rm -rf /var/lib/nginx 2>/dev/null || true
  rm -rf /var/log/nginx 2>/dev/null || true
  
  log "NPM uninstalled successfully"
  log "Data preserved in: ${DATA_DIR}"
  log "To remove data: rm -rf ${DATA_DIR}"
}

# -----------------------------
# Doctor/diagnostics
# -----------------------------
doctor() {
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${CYAN}  NPM System Diagnostics${NC}"
  echo -e "${BOLD}${CYAN}═══════════════════════════════════════════════════${NC}"
  echo ""
  
  echo -e "${BOLD}System Information:${NC}"
  echo "  OS: ${OS_ID} ${OS_VERSION} (${OS_CODENAME})"
  echo "  Kernel: $(uname -r)"
  echo "  Systemd: $(systemctl --version | head -n1)"
  echo ""
  
  echo -e "${BOLD}Installation Status:${NC}"
  detect_installation_type
  echo "  Installed: $(is_installed && echo YES || echo NO)"
  echo "  Installation type: ${INSTALL_TYPE}"
  echo "  Current version: $(get_current_version || echo "unknown")"
  echo ""
  
  echo -e "${BOLD}Dependencies:${NC}"
  echo "  Node.js: $(node -v 2>/dev/null || echo "NOT INSTALLED")"
  echo "  Yarn: $(yarn -v 2>/dev/null || echo "NOT INSTALLED")"
  echo "  OpenResty: $(openresty -v 2>&1 | head -n1 || echo "NOT INSTALLED")"
  echo "  Certbot: $(certbot --version 2>/dev/null || echo "NOT INSTALLED")"
  echo ""
  
  echo -e "${BOLD}Paths:${NC}"
  echo "  ${APP_DIR}: $([[ -d ${APP_DIR} ]] && echo "EXISTS" || echo "missing")"
  echo "  ${APP_DIR}/index.js: $([[ -f ${APP_DIR}/index.js ]] && echo "present" || echo "missing")"
  echo "  ${DATA_DIR}: $([[ -d ${DATA_DIR} ]] && echo "EXISTS" || echo "missing")"
  echo "  /etc/nginx: $([[ -d /etc/nginx ]] && echo "EXISTS" || echo "missing")"
  echo ""
  
  echo -e "${BOLD}Service Files:${NC}"
  if [[ -f "/lib/systemd/system/${SERVICE_APP}" ]]; then
    echo "  /lib/systemd/system/${SERVICE_APP}: present"
    local working_dir
    working_dir=$(systemctl show -p WorkingDirectory --value "${SERVICE_APP}" 2>/dev/null || echo "unknown")
    echo "    WorkingDirectory: ${working_dir}"
  elif [[ -f "/etc/systemd/system/${SERVICE_APP}" ]]; then
    echo "  /etc/systemd/system/${SERVICE_APP}: present"
  else
    echo "  ${SERVICE_APP}: NOT FOUND"
  fi
  echo ""
  
  echo -e "${BOLD}Service Status:${NC}"
  if systemctl list-unit-files "${SERVICE_NGINX}" >/dev/null 2>&1; then
    systemctl status "${SERVICE_NGINX}" --no-pager -n 5 2>&1 || true
  else
    echo "  ${SERVICE_NGINX}: not found"
  fi
  echo ""
  
  if systemctl list-unit-files "${SERVICE_APP}" >/dev/null 2>&1; then
    systemctl status "${SERVICE_APP}" --no-pager -n 5 2>&1 || true
  else
    echo "  ${SERVICE_APP}: not found"
  fi
  echo ""
  
  echo -e "${BOLD}Network:${NC}"
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 3 "http://127.0.0.1:81" >/dev/null 2>&1; then
      echo "  Admin UI (http://127.0.0.1:81): RESPONDING ✓"
    else
      echo "  Admin UI (http://127.0.0.1:81): NOT RESPONDING ✗"
    fi
  fi
  echo ""
  
  echo -e "${BOLD}Backups:${NC}"
  if [[ -d "${BACKUP_DIR}/previous" ]]; then
    local backup_ver
    backup_ver=$(cat "${BACKUP_DIR}/previous/.version" 2>/dev/null || echo "unknown")
    echo "  Previous backup: YES (version: ${backup_ver})"
  else
    echo "  Previous backup: NO"
  fi
  echo ""
}

# -----------------------------
# Main installation/update flow
# -----------------------------
perform_install_or_update() {
  local is_fresh_install=false
  
  detect_installation_type
  
  if [[ "${INSTALL_TYPE}" == "none" ]]; then
    is_fresh_install=true
  fi
  
  # Determine target version
  local target_ver
  if [[ "${TARGET_VERSION}" == "latest" ]]; then
    target_ver=$(get_latest_version)
  else
    target_ver="${TARGET_VERSION}"
  fi
  
  if ${is_fresh_install}; then
    # Fresh installation
    if [[ "${CHECK_ONLY}" == "true" ]]; then
      log "Not installed. Latest version available: ${target_ver}"
      return 0
    fi
    
    log "════════════════════════════════════════════════════════════"
    log "  FRESH INSTALLATION - Nginx Proxy Manager v${target_ver}"
    log "════════════════════════════════════════════════════════════"
    
    install_dependencies
    
    local tree
    tree="$(download_release_tree "${target_ver}")"
    patch_source_tree "${tree}" "${target_ver}"
    build_frontend "${tree}"
    
    deploy_environment_files "${tree}"
    deploy_runtime_app "${tree}" "${target_ver}"
    create_service
    configure_services
    start_services
    
    if healthcheck; then
      log "════════════════════════════════════════════════════════════"
      log "  ✓ Installation successful!"
      log "════════════════════════════════════════════════════════════"
      log "Access NPM at: http://YOUR_SERVER_IP:81"
      log "Default login: admin@example.com / changeme"
      log ""
      log "⚠  IMPORTANT: Change the default password immediately!"
    else
      die "Installation completed but health check failed"
    fi
    
  else
    # Update existing installation
    local current_ver
    current_ver=$(get_current_version)
    
    log "════════════════════════════════════════════════════════════"
    log "  UPDATE CHECK"
    log "════════════════════════════════════════════════════════════"
    log "Installation type: ${INSTALL_TYPE}"
    log "Current version: ${current_ver:-unknown}"
    log "Target version: ${target_ver}"
    
    if [[ -n "${current_ver}" ]] && ver_ge "${current_ver}" "${target_ver}" && [[ "${FORCE_UPDATE}" != "true" ]]; then
      log "Already up to date!"
      return 0
    fi
    
    if [[ "${CHECK_ONLY}" == "true" ]]; then
      log "Update available: ${current_ver:-unknown} → ${target_ver}"
      return 0
    fi
    
    log "Proceeding with update..."
    
    backup_current_version

    install_dependencies
    
    local tree
    tree="$(download_release_tree "${target_ver}")"
    patch_source_tree "${tree}" "${target_ver}"
    build_frontend "${tree}"
    
    stop_services
    deploy_environment_files "${tree}"
    deploy_runtime_app "${tree}" "${target_ver}"
    create_service
    configure_services
    start_services
    
    if healthcheck; then
      log "════════════════════════════════════════════════════════════"
      log "  ✓ Update successful!"
      log "════════════════════════════════════════════════════════════"
      log "Updated: ${current_ver:-unknown} → ${target_ver}"
    else
      warn "Update failed health check. Rolling back..."
      rollback_version || die "Rollback failed after failed update"
      die "Update failed and was rolled back to version ${current_ver:-unknown}"
    fi
  fi
  
  # Cleanup
  rm -rf "${TMP_DIR}" 2>/dev/null || true
  log "Done! 🎉"
}

# -----------------------------
# Command dispatching
# -----------------------------
CMD=""

# Parse command first
if [[ $# -gt 0 ]] && [[ "${1}" =~ ^(install|update|migrate|rollback|uninstall|status|logs|nginx-logs|install-log|install-logs|doctor)$ ]]; then
  CMD="$1"
  shift
fi

# Check for help/version flags anywhere
for arg in "$@"; do
  case "${arg}" in
    --help|-h|help) show_help; exit 0 ;;
    --version|-v|version) show_version; exit 0 ;;
  esac
done

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=true; shift ;;
    --force) FORCE_UPDATE=true; shift ;;
    --no-backup) NO_BACKUP=true; shift ;;
    --keep-data) KEEP_DATA_ON_ROLLBACK=true; shift ;;
    --takeover-nginx) TAKEOVER_NGINX=true; shift ;;
    --debug) DEBUG=true; shift ;;
    --target) 
      TARGET_VERSION="${2:-}"
      [[ -n "${TARGET_VERSION}" ]] || die "--target requires a version"
      shift 2 
      ;;
    --node) 
      NODE_MAJOR="${2:-}"
      [[ -n "${NODE_MAJOR}" ]] || die "--node requires a major version"
      shift 2 
      ;;
    *) die "Unknown option: $1 (run --help for usage)" ;;
  esac
done

# Execute command
require_root
require_systemd
init_logfile
acquire_lock
detect_os

case "${CMD}" in
  install|update|"")
    perform_install_or_update
    ;;
  migrate)
    MIGRATE_MODE=true
    migrate_from_old_installation
    ;;
  rollback)
    rollback_version
    ;;
  uninstall)
    uninstall_npm
    ;;
  status)
    systemctl status "${SERVICE_NGINX}" "${SERVICE_APP}" --no-pager
    ;;
  logs)
    journalctl -u "${SERVICE_APP}" -f
    ;;
  nginx-logs)
    journalctl -u "${SERVICE_NGINX}" -f
    ;;
  install-log)
    if [[ -f "${LOG_FILE}" ]]; then
      tail -n 200 "${LOG_FILE}"
    else
      echo "No log file found at ${LOG_FILE}"
    fi
    ;;
  install-logs)
    if [[ -f "${LOG_FILE}" ]]; then
      tail -n 200 -f "${LOG_FILE}"
    else
      echo "No log file found at ${LOG_FILE}"
    fi
    ;;
  doctor)
    doctor
    ;;
  *)
    die "Unknown command: ${CMD} (run --help for usage)"
    ;;
esac
