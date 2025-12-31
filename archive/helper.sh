#!/usr/bin/env bash
set -euo pipefail
umask 022

# Nginx Proxy Manager - Proxmox/Debian helper (community layout)
# - Supports legacy/community runtime layout: /app (backend runtime) + /app/frontend (built static)
# - Update to latest GitHub release
# - Backup + rollback
# - Installer log + service logs helpers
#
# Tested assumptions:
# - systemd present
# - openresty service exists (openresty.service)
# - npm service exists or will be created (npm.service)
#
# Author: adapted for your environment

VERSION="2.2.0"
REPO="NginxProxyManager/nginx-proxy-manager"

APP_DIR="/app"
DATA_DIR="/data"
BACKUP_DIR="/opt/npm-backups"
TMP_DIR="/tmp/npm-upgrade"
LOCK_FILE="/var/lock/npm-updater.lock"
LOG_FILE="/var/log/npm-updater.log"

SERVICE_APP="npm.service"
SERVICE_NGINX="openresty.service"

# Defaults (match community scripts better)
NODE_MAJOR_DEFAULT="22"
YARN_VERSION_DEFAULT="1.22.22"

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
TARGET_VERSION=""          # optional, override latest
NODE_MAJOR="${NODE_MAJOR_DEFAULT}"
YARN_VERSION="${YARN_VERSION_DEFAULT}"

# -----------------------------
# Logging (terminal colored, file plain)
# -----------------------------
ts() { date -Is; }

log() {
  local msg="$*"
  printf "%b[%s]%b %s\n" "${GREEN}" "$(ts)" "${NC}" "${msg}" >&2
  printf "[%s] %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}"
}

warn() {
  local msg="$*"
  printf "%b[%s] WARNING:%b %s\n" "${YELLOW}" "$(ts)" "${NC}" "${msg}" >&2
  printf "[%s] WARNING: %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}"
}

die() {
  local msg="$*"
  printf "%b[%s] ERROR:%b %s\n" "${RED}" "$(ts)" "${NC}" "${msg}" >&2
  printf "[%s] ERROR: %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}"
  exit 1
}

debug() {
  if [[ "${DEBUG}" == "true" ]]; then
    local msg="$*"
    printf "%b[%s] DEBUG:%b %s\n" "${MAGENTA}" "$(ts)" "${NC}" "${msg}" >&2
    printf "[%s] DEBUG: %s\n" "$(ts)" "${msg}" >> "${LOG_FILE}"
  fi
}

need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"; }

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

  local header="Nginx Proxy Manager - Install & Update Tool"
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
  echo -e "  ${CYAN}(none)${NC}          Install if missing, or update to latest version"
  echo -e "  ${CYAN}rollback${NC}        Restore previous version from backup"
  echo -e "  ${CYAN}status${NC}          Show systemd service status"
  echo -e "  ${CYAN}logs${NC}            Follow live NPM (backend) logs (journalctl -u ${SERVICE_APP})"
  echo -e "  ${CYAN}nginx-logs${NC}      Follow live OpenResty logs (journalctl -u ${SERVICE_NGINX})"
  echo -e "  ${CYAN}install-log${NC}     Show last 200 lines of installer log (${LOG_FILE})"
  echo -e "  ${CYAN}install-logs${NC}    Follow installer log (${LOG_FILE})"
  echo -e "  ${CYAN}doctor${NC}          Show detected layout, versions, key paths"
  echo -e "  ${CYAN}--help${NC}          Show this help screen"
  echo -e "  ${CYAN}--version${NC}       Show script version"
  echo ""

  echo -e "${BOLD}${GREEN}OPTIONS${NC}"
  echo -e "  ${YELLOW}--check-only${NC}   Check for updates without installing"
  echo -e "  ${YELLOW}--force${NC}         Force reinstall even if already up-to-date"
  echo -e "  ${YELLOW}--no-backup${NC}     Skip backup (faster but no rollback possible)"
  echo -e "  ${YELLOW}--keep-data${NC}     On rollback, keep current /data (default restores /data too)"
  echo -e "  ${YELLOW}--target <ver>${NC}  Install/upgrade to a specific version (example: 2.13.5)"
  echo -e "  ${YELLOW}--node <major>${NC}  Node.js major (default: ${NODE_MAJOR_DEFAULT})"
  echo -e "  ${YELLOW}--debug${NC}         More verbose logging"
  echo ""

  echo -e "${BOLD}${GREEN}EXAMPLES${NC}"
  echo -e "  ${DIM}# Install or update to latest${NC}"
  echo -e "  sudo $(basename "$0")"
  echo ""
  echo -e "  ${DIM}# Check without installing${NC}"
  echo -e "  sudo $(basename "$0") --check-only"
  echo ""
  echo -e "  ${DIM}# Force reinstall${NC}"
  echo -e "  sudo $(basename "$0") --force"
  echo ""
  echo -e "  ${DIM}# Update without backup${NC}"
  echo -e "  sudo $(basename "$0") --no-backup"
  echo ""
  echo -e "  ${DIM}# Rollback${NC}"
  echo -e "  sudo $(basename "$0") rollback"
  echo ""
  echo -e "  ${DIM}# Keep current /data when rolling back${NC}"
  echo -e "  sudo $(basename "$0") --keep-data rollback"
  echo ""

  echo -e "${BOLD}${GREEN}FEATURES${NC}"
  echo -e "  ${BLUE}•${NC} Community layout compatible (/app runtime)"
  echo -e "  ${BLUE}•${NC} Downloads latest release from GitHub"
  echo -e "  ${BLUE}•${NC} Keeps one previous version for rollback"
  echo -e "  ${BLUE}•${NC} Automatic rollback if deploy/build fails"
  echo -e "  ${BLUE}•${NC} Full installer logging to ${LOG_FILE}"
  echo -e "  ${BLUE}•${NC} Locking to prevent concurrent runs (${LOCK_FILE})"
  echo ""

  echo -e "${BOLD}${GREEN}DIRECTORY STRUCTURE${NC}"
  echo -e "  ${MAGENTA}${APP_DIR}${NC}                       Application runtime (backend)"
  echo -e "  ${MAGENTA}${DATA_DIR}${NC}                      Configuration & data"
  echo -e "  ${MAGENTA}${BACKUP_DIR}/previous${NC}          Rollback backup"
  echo -e "  ${MAGENTA}${LOG_FILE}${NC}   Installer logs"
  echo ""

  echo -e "${BOLD}${GREEN}SERVICES${NC}"
  echo -e "  ${CYAN}${SERVICE_APP}${NC}                NPM backend (Node.js, /app)"
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
  echo -e "  ${YELLOW}⚠  Change these immediately after first login!${NC}"
  echo ""

  echo -e "${BOLD}${GREEN}NOTES${NC}"
  echo -e "  ${DIM}•${NC} Requires root privileges"
  echo -e "  ${DIM}•${NC} Requires systemd (Debian/Ubuntu supported)"
  echo -e "  ${DIM}•${NC} Uses Yarn classic for frontend build (community compatible)"
  echo -e "  ${DIM}•${NC} Optional: export ${CYAN}GITHUB_TOKEN${NC} to avoid GitHub API rate limits"
  echo ""

  printf '%*s' "$max_width" | tr ' ' '─'
  echo ""
  echo -e "${DIM}Repository: https://github.com/${REPO}${NC}"
  printf '%*s' "$max_width" | tr ' ' '─'
  echo ""
}

show_version() {
  echo -e "${BOLD}${CYAN}NPM Install & Update Tool${NC} v${VERSION}"
  echo -e "${DIM}Repository: https://github.com/${REPO}${NC}"
}

# -----------------------------
# Preconditions/locking
# -----------------------------
require_root() {
  [[ ${EUID} -eq 0 ]] || die "Run as root."
}

require_systemd() {
  need_cmd systemctl
}

acquire_lock() {
  mkdir -p "$(dirname "${LOCK_FILE}")"
  exec 9>"${LOCK_FILE}"
  if ! flock -n 9; then
    die "Another run is in progress (lock: ${LOCK_FILE})."
  fi
}

init_logfile() {
  mkdir -p "$(dirname "${LOG_FILE}")"
  touch "${LOG_FILE}"
  chmod 600 "${LOG_FILE}"
}

# -----------------------------
# OS detect + deps
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
  log "Detected OS: ${OS_ID} ${OS_VERSION}"
}

curl_json() {
  # Usage: curl_json URL
  local url="$1"
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    curl -fsSL --retry 3 --retry-delay 1 \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: npm-updater" \
      "${url}"
  else
    curl -fsSL --retry 3 --retry-delay 1 \
      -H "Accept: application/vnd.github+json" \
      -H "User-Agent: npm-updater" \
      "${url}"
  fi
}

ensure_node() {
  need_cmd curl
  case "${OS_ID}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq

      local need_install=false
      if ! command -v node >/dev/null 2>&1; then
        need_install=true
      else
        local cur_major
        cur_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
        if [[ "${cur_major}" -lt "${NODE_MAJOR}" ]]; then
          warn "Node.js v$(node -v 2>/dev/null || echo unknown) found, but v${NODE_MAJOR}+ required. Upgrading..."
          need_install=true
        else
          log "Node.js v$(node -v) is compatible"
        fi
      fi

      if [[ "${need_install}" == "true" ]]; then
        log "Installing Node.js ${NODE_MAJOR} (NodeSource)..."
        apt-get install -y -qq ca-certificates curl gnupg >/dev/null
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR}.x" | bash - >/dev/null 2>&1 || true
        apt-get install -y -qq nodejs >/dev/null
      fi
      ;;
    *)
      die "Unsupported OS for this helper: ${OS_ID}"
      ;;
  esac
}

ensure_yarn() {
  # Prefer corepack if present (Node 16+)
  if command -v corepack >/dev/null 2>&1; then
    debug "Using corepack for yarn"
    corepack enable >/dev/null 2>&1 || true
    corepack prepare "yarn@${YARN_VERSION}" --activate >/dev/null 2>&1 || true
  fi
  if ! command -v yarn >/dev/null 2>&1; then
    log "Installing yarn@${YARN_VERSION}..."
    npm install -g "yarn@${YARN_VERSION}" >/dev/null
  fi
  log "yarn version: $(yarn -v 2>/dev/null || echo unknown)"
}

ensure_build_deps() {
  case "${OS_ID}" in
    debian|ubuntu)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -qq
      apt-get install -y -qq \
        ca-certificates curl wget git tar gzip \
        build-essential \
        python3 python3-venv python3-pip \
        openssl \
        logrotate \
        apache2-utils >/dev/null
      ;;
    *)
      die "Unsupported OS for dependencies: ${OS_ID}"
      ;;
  esac
}

ensure_openresty() {
  if command -v openresty >/dev/null 2>&1; then
    log "OpenResty already installed: $(command -v openresty)"
    return 0
  fi

  case "${OS_ID}" in
    debian|ubuntu)
      log "Installing OpenResty..."
      apt-get install -y -qq gnupg >/dev/null

      # OpenResty repo
      curl -fsSL "https://openresty.org/package/pubkey.gpg" | gpg --dearmor --yes -o /etc/apt/trusted.gpg.d/openresty.gpg

      # Use codename if present, fallback to bookworm
      local suite="${OS_CODENAME:-bookworm}"
      if [[ -z "${suite}" ]]; then suite="bookworm"; fi

      cat <<EOF >/etc/apt/sources.list.d/openresty.sources
Types: deb
URIs: http://openresty.org/package/debian/
Suites: ${suite}
Components: openresty
Signed-By: /etc/apt/trusted.gpg.d/openresty.gpg
EOF

      apt-get update -qq
      apt-get install -y -qq openresty >/dev/null
      ;;
    *)
      die "OpenResty install not supported on: ${OS_ID}"
      ;;
  esac
}

ensure_certbot() {
  if command -v certbot >/dev/null 2>&1; then
    log "certbot already installed"
    return 0
  fi
  log "Setting up certbot venv (/opt/certbot)..."
  python3 -m venv /opt/certbot
  /opt/certbot/bin/pip install --upgrade pip setuptools wheel >/dev/null
  /opt/certbot/bin/pip install certbot certbot-dns-cloudflare >/dev/null
  ln -sf /opt/certbot/bin/certbot /usr/local/bin/certbot
  log "certbot installed"
}

install_dependencies() {
  log "Installing system dependencies..."
  ensure_build_deps
  ensure_node
  ensure_yarn
  ensure_certbot
  ensure_openresty
  log "Dependencies installed successfully"
}

# -----------------------------
# Install detection + version
# -----------------------------
is_installed() {
  [[ -f "/lib/systemd/system/${SERVICE_APP}" || -f "/etc/systemd/system/${SERVICE_APP}" ]] && [[ -f "${APP_DIR}/index.js" ]]
}

get_current_version() {
  # Community layout: /app/package.json
  if [[ -f "${APP_DIR}/package.json" ]]; then
    sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${APP_DIR}/package.json" | head -n1
    return 0
  fi
  if [[ -f "${APP_DIR}/.version" ]]; then
    tr -d '[:space:]' < "${APP_DIR}/.version" | sed 's/^v//'
    return 0
  fi
  echo ""
}

get_latest_version() {
  local json tag
  json="$(curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: npm-updater" \
    "https://api.github.com/repos/${REPO}/releases/latest")" || die "Could not fetch latest release info from GitHub API."

  tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  [[ -n "$tag" ]] || die "Could not parse tag_name from GitHub JSON."

  echo "${tag#v}"
}


ver_ge() {
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# -----------------------------
# Backup/rollback
# -----------------------------
backup_current_version() {
  if ! is_installed; then
    log "No existing installation to backup"
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
  log "Backing up current version (${cur:-unknown}) to ${BACKUP_DIR}/previous"

  # runtime + config + unit
  for p in \
    "${APP_DIR}" \
    "/etc/nginx" \
    "/var/www/html" \
    "/etc/logrotate.d/nginx-proxy-manager" \
    "/etc/letsencrypt.ini" \
    "/lib/systemd/system/${SERVICE_APP}" \
    "/etc/systemd/system/${SERVICE_APP}"
  do
    if [[ -e "${p}" ]]; then
      mkdir -p "${BACKUP_DIR}/previous$(dirname "${p}")"
      cp -a "${p}" "${BACKUP_DIR}/previous${p}"
    fi
  done

  # data optional (default restores /data too)
  if [[ -d "${DATA_DIR}" ]]; then
    mkdir -p "${BACKUP_DIR}/previous${DATA_DIR}"
    cp -a "${DATA_DIR}" "${BACKUP_DIR}/previous${DATA_DIR}"
  fi

  echo "${cur:-unknown}" > "${BACKUP_DIR}/previous/.version"
  log "Backup complete"
}

rollback_version() {
  if [[ ! -d "${BACKUP_DIR}/previous" ]]; then
    warn "No backup found to rollback to!"
    return 1
  fi

  local prev
  prev="$(cat "${BACKUP_DIR}/previous/.version" 2>/dev/null || echo unknown)"
  log "Rolling back to previous version (${prev})..."

  systemctl stop "${SERVICE_APP}" 2>/dev/null || true
  systemctl stop "${SERVICE_NGINX}" 2>/dev/null || true

  # Restore runtime/config
  for p in \
    "${APP_DIR}" \
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

  # Restore unit if present
  if [[ -f "${BACKUP_DIR}/previous/lib/systemd/system/${SERVICE_APP}" ]]; then
    cp -a "${BACKUP_DIR}/previous/lib/systemd/system/${SERVICE_APP}" "/lib/systemd/system/${SERVICE_APP}"
  fi
  if [[ -f "${BACKUP_DIR}/previous/etc/systemd/system/${SERVICE_APP}" ]]; then
    cp -a "${BACKUP_DIR}/previous/etc/systemd/system/${SERVICE_APP}" "/etc/systemd/system/${SERVICE_APP}"
  fi

  if [[ "${KEEP_DATA_ON_ROLLBACK}" != "true" ]]; then
    if [[ -d "${BACKUP_DIR}/previous${DATA_DIR}" ]]; then
      rm -rf "${DATA_DIR}"
      cp -a "${BACKUP_DIR}/previous${DATA_DIR}" "${DATA_DIR}"
    fi
  else
    warn "Keeping current ${DATA_DIR} (requested by --keep-data)"
  fi

  systemctl daemon-reload 2>/dev/null || true
  systemctl start "${SERVICE_NGINX}" 2>/dev/null || true
  sleep 2
  systemctl start "${SERVICE_APP}" 2>/dev/null || true

  log "Rollback complete!"
  return 0
}

# -----------------------------
# Download/build/deploy (community compatible)
# -----------------------------
download_release_tree() {
  local ver="$1"
  rm -rf "${TMP_DIR}"
  mkdir -p "${TMP_DIR}"
  cd "${TMP_DIR}"

  local url="https://codeload.github.com/${REPO}/tar.gz/v${ver}"
  log "Downloading NPM v${ver}..."
  curl -fsSL --retry 3 --retry-delay 1 "${url}" -o release.tgz
  log "Extracting release..."
  tar -xzf release.tgz

  local extracted="nginx-proxy-manager-${ver}"
  if [[ ! -d "${extracted}" ]]; then
    extracted="$(find . -maxdepth 1 -type d -name "nginx-proxy-manager-*" | head -n1)"
  fi
  [[ -n "${extracted}" && -d "${extracted}" ]] || die "Could not find extracted directory."

  # return path on stdout only
  printf "%s\n" "${TMP_DIR}/${extracted}"
}

patch_source_tree() {
  local tree="$1"
  local ver="$2"

  debug "Patching source tree at ${tree} for version ${ver}"

  # Patch version fields robustly (handle 0.0.0 or 2.0.0)
  if [[ -f "${tree}/backend/package.json" ]]; then
    sed -i -E "s/\"version\"[[:space:]]*:[[:space:]]*\"(0\.0\.0|2\.0\.0)\"/\"version\": \"${ver}\"/g" "${tree}/backend/package.json" || true
  fi
  if [[ -f "${tree}/frontend/package.json" ]]; then
    sed -i -E "s/\"version\"[[:space:]]*:[[:space:]]*\"(0\.0\.0|2\.0\.0)\"/\"version\": \"${ver}\"/g" "${tree}/frontend/package.json" || true
  fi

  # Comment daemon in nginx.conf inside docker rootfs (community scripts do this)
  if [[ -f "${tree}/docker/rootfs/etc/nginx/nginx.conf" ]]; then
    sed -i 's+^daemon+#daemon+g' "${tree}/docker/rootfs/etc/nginx/nginx.conf" || true
  fi

  # Fix include path in all *.conf so they point to /etc/nginx/conf.d
  local conf
  while IFS= read -r -d '' conf; do
    sed -i 's+include conf.d+include /etc/nginx/conf.d+g' "${conf}" || true
  done < <(find "${tree}" -type f -name "*.conf" -print0 2>/dev/null || true)

  # Replace node-sass with sass in frontend package.json (avoid node-sass pain)
  if [[ -f "${tree}/frontend/package.json" ]]; then
    if grep -q '"node-sass"' "${tree}/frontend/package.json"; then
      log "Patching frontend package.json: node-sass -> sass"
      # Replace any "node-sass": "x" with "sass": "^1.92.1"
      sed -i -E 's/"node-sass"[[:space:]]*:[[:space:]]*"[^"]*"/"sass": "^1.92.1"/g' "${tree}/frontend/package.json" || true
    fi
  fi
}

build_frontend() {
  local tree="$1"

  log "Building frontend..."
  export NODE_OPTIONS="--max_old_space_size=2048 --openssl-legacy-provider"
  cd "${tree}/frontend"

  yarn install --network-timeout 600000

  # locale compile if script exists
  if grep -q '"locale-compile"' package.json 2>/dev/null; then
    log "Compiling locales..."
    yarn locale-compile
  fi

  log "Building frontend (yarn build)..."
  yarn build
}

deploy_environment_files() {
  local tree="$1"

  log "Setting up environment files (/etc/nginx, /var/www/html, logrotate, letsencrypt.ini)..."

  ln -sf /usr/bin/python3 /usr/bin/python 2>/dev/null || true
  ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx 2>/dev/null || true
  ln -sf /usr/local/openresty/nginx/ /etc/nginx 2>/dev/null || true

  # Clean old files (community style)
  rm -rf \
    "${APP_DIR}" \
    /var/www/html \
    /etc/nginx \
    /var/log/nginx \
    /var/lib/nginx \
    /var/cache/nginx || true

  mkdir -p /var/www/html /etc/nginx/logs

  if [[ -d "${tree}/docker/rootfs/var/www/html" ]]; then
    cp -r "${tree}/docker/rootfs/var/www/html/"* /var/www/html/
  fi
  if [[ -d "${tree}/docker/rootfs/etc/nginx" ]]; then
    cp -r "${tree}/docker/rootfs/etc/nginx/"* /etc/nginx/
  fi
  if [[ -f "${tree}/docker/rootfs/etc/letsencrypt.ini" ]]; then
    cp "${tree}/docker/rootfs/etc/letsencrypt.ini" /etc/letsencrypt.ini
  fi
  if [[ -f "${tree}/docker/rootfs/etc/logrotate.d/nginx-proxy-manager" ]]; then
    cp "${tree}/docker/rootfs/etc/logrotate.d/nginx-proxy-manager" /etc/logrotate.d/nginx-proxy-manager
  fi

  ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf 2>/dev/null || true
  rm -f /etc/nginx/conf.d/dev.conf 2>/dev/null || true

  # Required dirs
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

  chmod -R 777 /var/cache/nginx 2>/dev/null || true
  chown root /tmp/nginx 2>/dev/null || true

  mkdir -p /etc/nginx/conf.d/include 2>/dev/null || true
  if [[ -f /etc/resolv.conf ]]; then
    echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf);" \
      > /etc/nginx/conf.d/include/resolvers.conf
  fi

  if [[ ! -f /data/nginx/dummycert.pem || ! -f /data/nginx/dummykey.pem ]]; then
    log "Generating dummy SSL cert..."
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" \
      -keyout /data/nginx/dummykey.pem \
      -out /data/nginx/dummycert.pem >/dev/null 2>&1
  fi
}

deploy_runtime_app() {
  local tree="$1"
  local ver="$2"

  log "Deploying runtime to ${APP_DIR}..."
  mkdir -p "${APP_DIR}" /app/frontend/images /app/global

  # Copy backend runtime files
  cp -r "${tree}/backend/"* "${APP_DIR}/"

  # Copy global if exists
  if [[ -d "${tree}/global" ]]; then
    cp -r "${tree}/global/"* /app/global/ 2>/dev/null || true
  fi

  # Copy built frontend artifacts
  if [[ -d "${tree}/frontend/dist" ]]; then
    cp -r "${tree}/frontend/dist/"* /app/frontend/
  fi

  # Images path differs between script versions: app-images or public/images
  if [[ -d "${tree}/frontend/app-images" ]]; then
    cp -r "${tree}/frontend/app-images/"* /app/frontend/images/ 2>/dev/null || true
  elif [[ -d "${tree}/frontend/public/images" ]]; then
    cp -r "${tree}/frontend/public/images/"* /app/frontend/images/ 2>/dev/null || true
  fi

  # Write a helper version marker for your script (optional)
  echo "${ver}" > "${APP_DIR}/.version"

  log "Initializing backend (yarn install in /app)..."
  rm -rf /app/config/default.json 2>/dev/null || true

  if [[ ! -f /app/config/production.json ]]; then
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

  cd /app
  export NODE_OPTIONS="--openssl-legacy-provider"
  yarn install --network-timeout 600000
}

create_service_if_missing() {
  if [[ -f "/lib/systemd/system/${SERVICE_APP}" ]]; then
    debug "Service ${SERVICE_APP} already exists"
    return 0
  fi

  log "Creating ${SERVICE_APP}..."
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
}

start_services() {
  log "Starting services..."
  # Align some configs like community scripts
  sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf 2>/dev/null || true
  if [[ -f /etc/logrotate.d/nginx-proxy-manager ]]; then
    # Avoid su npm errors on some installs
    sed -r -i 's/^([[:space:]]*)su npm npm/\1#su npm npm/g;' /etc/logrotate.d/nginx-proxy-manager 2>/dev/null || true
  fi

  systemctl enable -q --now "${SERVICE_NGINX}" 2>/dev/null || true
  systemctl enable -q --now "${SERVICE_APP}" 2>/dev/null || true
  systemctl restart "${SERVICE_NGINX}" 2>/dev/null || true
  sleep 1
  systemctl restart "${SERVICE_APP}" 2>/dev/null || true
}

stop_services() {
  log "Stopping services..."
  systemctl stop "${SERVICE_APP}" 2>/dev/null || true
  systemctl stop "${SERVICE_NGINX}" 2>/dev/null || true
}

healthcheck() {
  log "Running healthcheck..."
  local retries=12
  local i=0

  while [[ $i -lt $retries ]]; do
    if systemctl is-active --quiet "${SERVICE_APP}" && systemctl is-active --quiet "${SERVICE_NGINX}"; then
      if curl -fsS "http://127.0.0.1:81" >/dev/null 2>&1 || curl -fsS "http://localhost:81" >/dev/null 2>&1; then
        log "✓ Services running and admin UI responds on :81"
        return 0
      fi
    fi
    i=$((i+1))
    sleep 2
  done

  warn "Healthcheck failed."
  systemctl status "${SERVICE_APP}" --no-pager -n 30 || true
  systemctl status "${SERVICE_NGINX}" --no-pager -n 30 || true
  return 1
}

doctor() {
  require_systemd
  echo -e "${BOLD}${CYAN}Doctor${NC}"
  echo -e "Installed: $(is_installed && echo yes || echo no)"
  echo -e "Current version (app): $(get_current_version || true)"
  echo -e "npm.service file: $([[ -f /lib/systemd/system/npm.service ]] && echo /lib/systemd/system/npm.service || echo missing)"
  echo -e "WorkingDirectory: $(systemctl show -p WorkingDirectory --value npm.service 2>/dev/null || echo unknown)"
  echo -e "/app/index.js: $([[ -f /app/index.js ]] && echo present || echo missing)"
  echo -e "/app/backend: $([[ -d /app/backend ]] && echo present || echo missing)"
  echo -e "openresty: $(command -v openresty 2>/dev/null || echo missing)"
  echo -e "node: $(node -v 2>/dev/null || echo missing)"
  echo -e "yarn: $(yarn -v 2>/dev/null || echo missing)"
  echo ""
  systemctl status "${SERVICE_NGINX}" "${SERVICE_APP}" --no-pager -n 10 || true
}

# -----------------------------
# Main flow
# -----------------------------
main() {
  require_root
  require_systemd
  init_logfile
  acquire_lock
  detect_os

  local latest current tree
  if [[ -n "${TARGET_VERSION}" ]]; then
    latest="${TARGET_VERSION}"
  else
    latest="$(get_latest_version)"
  fi

  if ! is_installed; then
    if [[ "${CHECK_ONLY}" == "true" ]]; then
      log "Not installed. Latest version available: ${latest}"
      return 0
    fi

    log "════════════════════════════════════════════════════════════"
    log "  FRESH INSTALLATION - Nginx Proxy Manager v${latest}"
    log "════════════════════════════════════════════════════════════"

    install_dependencies

    tree="$(download_release_tree "${latest}")"
    patch_source_tree "${tree}" "${latest}"
    build_frontend "${tree}"

    stop_services
    if [[ "${NO_BACKUP}" != "true" ]]; then
      backup_current_version || true
    fi

    deploy_environment_files "${tree}"
    deploy_runtime_app "${tree}" "${latest}"
    create_service_if_missing
    start_services

    if healthcheck; then
      log "════════════════════════════════════════════════════════════"
      log "  ✓ Installation successful!"
      log "════════════════════════════════════════════════════════════"
      log "Access: http://YOUR_SERVER_IP:81"
      log "Default: admin@example.com / changeme"
    else
      die "Installation completed but failed healthcheck."
    fi

  else
    current="$(get_current_version)"
    log "════════════════════════════════════════════════════════════"
    log "  UPDATE CHECK"
    log "════════════════════════════════════════════════════════════"
    log "Current version: ${current:-unknown}"
    log "Latest version:  ${latest}"

    if [[ -n "${current}" ]] && ver_ge "${current}" "${latest}" && [[ "${FORCE_UPDATE}" != "true" ]]; then
      log "Already up to date!"
      return 0
    fi

    if [[ "${CHECK_ONLY}" == "true" ]]; then
      log "Update available: ${current:-unknown} → ${latest}"
      return 0
    fi

    log "Update available! Proceeding with upgrade..."

    install_dependencies

    stop_services
    backup_current_version

    tree="$(download_release_tree "${latest}")"
    patch_source_tree "${tree}" "${latest}"
    build_frontend "${tree}"

    deploy_environment_files "${tree}"
    deploy_runtime_app "${tree}" "${latest}"
    create_service_if_missing
    start_services

    if healthcheck; then
      log "════════════════════════════════════════════════════════════"
      log "  ✓ Update successful! v${current:-unknown} → v${latest}"
      log "════════════════════════════════════════════════════════════"
    else
      warn "Update failed healthcheck. Rolling back..."
      rollback_version || die "Rollback failed after failed update."
      die "Update failed healthcheck and was rolled back."
    fi
  fi

  rm -rf "${TMP_DIR}" 2>/dev/null || true
  log "Done! 🎉"
}

# -----------------------------
# Arg parsing + dispatcher
# -----------------------------
CMD=""

if [[ "${1:-}" =~ ^(rollback|status|logs|nginx-logs|install-log|install-logs|doctor)$ ]]; then
  CMD="$1"
  shift
fi

# allow help/version anywhere
for arg in "$@"; do
  case "${arg}" in
    --help|-h|help) show_help; exit 0 ;;
    --version|-v|version) show_version; exit 0 ;;
  esac
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check-only) CHECK_ONLY=true; shift ;;
    --force) FORCE_UPDATE=true; shift ;;
    --no-backup) NO_BACKUP=true; shift ;;
    --keep-data) KEEP_DATA_ON_ROLLBACK=true; shift ;;
    --debug) DEBUG=true; shift ;;
    --target) TARGET_VERSION="${2:-}"; [[ -n "${TARGET_VERSION}" ]] || die "--target requires a version"; shift 2 ;;
    --node) NODE_MAJOR="${2:-}"; [[ -n "${NODE_MAJOR}" ]] || die "--node requires a major version"; shift 2 ;;
    *) die "Unknown option: $1 (run --help)" ;;
  esac
done

case "${CMD}" in
  rollback)
    require_root; require_systemd; init_logfile; acquire_lock; detect_os
    rollback_version
    ;;
  status)
    require_root; require_systemd
    systemctl status "${SERVICE_NGINX}" "${SERVICE_APP}" --no-pager
    ;;
  logs)
    require_root; require_systemd
    journalctl -u "${SERVICE_APP}" -f
    ;;
  nginx-logs)
    require_root; require_systemd
    journalctl -u "${SERVICE_NGINX}" -f
    ;;
  install-log)
    require_root; init_logfile
    tail -n 200 "${LOG_FILE}"
    ;;
  install-logs)
    require_root; init_logfile
    tail -n 200 -f "${LOG_FILE}"
    ;;
  doctor)
    require_root; init_logfile; detect_os
    doctor
    ;;
  *)
    main
    ;;
esac
