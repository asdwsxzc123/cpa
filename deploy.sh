#!/usr/bin/env bash
#
# deploy.sh - CLIProxyAPI build & deploy script (Linux)
#
# Builds from local source, installs to $HOME/cliproxyapi, and manages the
# binary as a systemd --user service. Preserves config.yaml on upgrade.
# Inspired by router-for-me/cliproxyapi-installer but builds from source.

set -euo pipefail

# ===== Config =====
INSTALL_DIR="${CLIPROXY_INSTALL_DIR:-$HOME/cliproxyapi}"
SERVICE_NAME="cliproxyapi"
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
BIN_NAME="cli-proxy-api"
KEEP_VERSIONS=2

REPO_URL="${CLIPROXY_REPO_URL:-https://github.com/asdwsxzc123/cpa.git}"
REPO_REF="${CLIPROXY_REPO_REF:-v7.1.17}"   # pinned tag; override via CLIPROXY_REPO_REF
WORK_DIR="${CLIPROXY_WORK_DIR:-$HOME/.cache/cliproxyapi-src}"

# Binary download mode is the default: fetch prebuilt asset from this repo's
# GitHub Releases. To fall back to source build, pass CLIPROXY_BIN_URL= (empty).
# CLIPROXY_BIN_VERSION  release tag (default: v7.1.17); also written to version.txt
# CLIPROXY_BIN_URL      override binary URL entirely (empty = source build)
# CLIPROXY_CFG_URL      override config.example.yaml URL
# CLIPROXY_AUTH_HEADER  optional HTTP header for auth (e.g. "Authorization: token ghp_xxx")
BIN_VERSION="${CLIPROXY_BIN_VERSION:-v7.1.17}"
case "$(uname -m)" in
  x86_64|amd64)   _BIN_ARCH=amd64 ;;
  aarch64|arm64)  _BIN_ARCH=aarch64 ;;
  *)              _BIN_ARCH="" ;;
esac
_BIN_VER_NOV="${BIN_VERSION#v}"
if [ -n "$_BIN_ARCH" ]; then
  _DEFAULT_BIN_URL="https://github.com/asdwsxzc123/cpa/releases/download/${BIN_VERSION}/cpa_${_BIN_VER_NOV}_linux_${_BIN_ARCH}.tar.gz"
else
  _DEFAULT_BIN_URL=""
fi
# Use ${VAR-default} (no colon) so explicit empty disables binary mode.
BIN_URL="${CLIPROXY_BIN_URL-$_DEFAULT_BIN_URL}"
CFG_URL="${CLIPROXY_CFG_URL-https://raw.githubusercontent.com/asdwsxzc123/cpa/${BIN_VERSION}/config.example.yaml}"
AUTH_HEADER="${CLIPROXY_AUTH_HEADER:-}"

# Resolve SCRIPT_DIR if invoked via a real file; falls back to "" when piped.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  SCRIPT_DIR=""
fi

# ===== Logging =====
log_info()    { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
log_success() { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
log_warning() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
log_error()   { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }
log_step()    { printf '\n\033[35m==>\033[0m %s\n' "$*"; }

# ===== Checks =====
check_dependencies() {
  local required=(tar systemctl)
  if [ -n "$BIN_URL" ]; then
    # Binary mode: no go/git, just a downloader.
    command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
      || { log_error "Need curl or wget for binary download"; exit 1; }
  else
    required+=(go git)
  fi
  local missing=()
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    log_error "Missing required commands: ${missing[*]}"
    exit 1
  fi
}

# Download URL -> file path. Honors CLIPROXY_AUTH_HEADER. Uses curl or wget.
download() {
  local url="$1" dest="$2"
  log_info "Downloading $url"
  if command -v curl >/dev/null 2>&1; then
    if [ -n "$AUTH_HEADER" ]; then
      curl -fsSL -H "$AUTH_HEADER" -o "$dest" "$url"
    else
      curl -fsSL -o "$dest" "$url"
    fi
  else
    if [ -n "$AUTH_HEADER" ]; then
      wget -q --header="$AUTH_HEADER" -O "$dest" "$url"
    else
      wget -q -O "$dest" "$url"
    fi
  fi
}

is_installed()         { [ -f "$INSTALL_DIR/version.txt" ]; }
current_version()      { cat "$INSTALL_DIR/version.txt" 2>/dev/null || echo "none"; }
is_service_running()   { systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; }

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) log_error "Unsupported arch: $(uname -m)"; exit 1 ;;
  esac
}

# ===== Source =====
# If SCRIPT_DIR is a checkout, use it; otherwise clone REPO_URL to WORK_DIR.
ensure_source() {
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/go.mod" ] && [ -d "$SCRIPT_DIR/cmd/server" ]; then
    log_info "Using local source: $SCRIPT_DIR"
    return
  fi

  log_step "Fetching source -> $WORK_DIR"
  if [ -d "$WORK_DIR/.git" ]; then
    git -C "$WORK_DIR" fetch --tags --prune origin
    git -C "$WORK_DIR" reset --hard "${REPO_REF:-origin/HEAD}"
  else
    mkdir -p "$(dirname "$WORK_DIR")"
    rm -rf "$WORK_DIR"
    if [ -n "$REPO_REF" ]; then
      git clone "$REPO_URL" "$WORK_DIR"
      git -C "$WORK_DIR" checkout "$REPO_REF"
    else
      git clone --depth=1 "$REPO_URL" "$WORK_DIR"
    fi
  fi
  SCRIPT_DIR="$WORK_DIR"
  log_success "Source ready at $SCRIPT_DIR"
}

# ===== Binary install =====
install_from_binary() {
  log_step "Installing from binary URL"
  local version; version="${BIN_VERSION:-bin-$(date +%Y%m%d%H%M%S)}"
  local out_dir="$INSTALL_DIR/$version"
  mkdir -p "$out_dir"

  local tmp; tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' RETURN

  # Save to a temp file, detect tar.gz vs raw binary by extension/magic.
  local tmpfile="$tmp/payload"
  download "$BIN_URL" "$tmpfile"

  if file "$tmpfile" 2>/dev/null | grep -qi 'gzip'; then
    log_info "Extracting archive..."
    tar -xzf "$tmpfile" -C "$tmp"
    # Find the binary in the extracted tree.
    local found
    found="$(find "$tmp" -type f -name "$BIN_NAME" -o -name 'CLIProxyAPI' | head -n1)"
    if [ -z "$found" ]; then
      log_error "No $BIN_NAME / CLIProxyAPI found in archive"
      exit 1
    fi
    cp "$found" "$out_dir/$BIN_NAME"
  else
    cp "$tmpfile" "$out_dir/$BIN_NAME"
  fi
  chmod +x "$out_dir/$BIN_NAME"

  if [ -n "$CFG_URL" ]; then
    download "$CFG_URL" "$out_dir/config.example.yaml"
  fi

  echo "$version" > "$INSTALL_DIR/version.txt"
  ln -sfn "$out_dir/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
  log_success "Binary installed at $out_dir/$BIN_NAME (version: $version)"
}

# ===== Build =====
build_from_source() {
  log_step "Building from $SCRIPT_DIR"
  cd "$SCRIPT_DIR"

  if [ ! -f "go.mod" ] || [ ! -d "cmd/server" ]; then
    log_error "Source layout not found at $SCRIPT_DIR"
    exit 1
  fi

  local version commit build_date arch
  version="$(git describe --tags --always --dirty 2>/dev/null || echo "dev-$(date +%Y%m%d%H%M%S)")"
  commit="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  arch="$(detect_arch)"

  log_info "Version:    $version"
  log_info "Commit:     $commit"
  log_info "Build date: $build_date"
  log_info "Target:     linux/$arch"

  local out_dir="$INSTALL_DIR/$version"
  mkdir -p "$out_dir"

  log_info "Compiling..."
  CGO_ENABLED=0 GOOS=linux GOARCH="$arch" \
    go build \
      -ldflags="-s -w -X 'main.Version=${version}' -X 'main.Commit=${commit}' -X 'main.BuildDate=${build_date}'" \
      -o "$out_dir/$BIN_NAME" \
      ./cmd/server

  cp -f config.example.yaml "$out_dir/config.example.yaml"
  echo "$version" > "$INSTALL_DIR/version.txt"

  ln -sfn "$out_dir/$BIN_NAME" "$INSTALL_DIR/$BIN_NAME"
  log_success "Binary at $out_dir/$BIN_NAME"
}

# ===== Config =====
backup_config() {
  [ -f "$INSTALL_DIR/config.yaml" ] || return 0
  local backup_dir="$INSTALL_DIR/config_backup"
  mkdir -p "$backup_dir"
  local ts; ts="$(date +%Y%m%d_%H%M%S)"
  cp "$INSTALL_DIR/config.yaml" "$backup_dir/config_$ts.yaml"
  log_info "Backed up config -> $backup_dir/config_$ts.yaml"
}

setup_config() {
  if [ -f "$INSTALL_DIR/config.yaml" ]; then
    log_info "Keeping existing config.yaml"
    return
  fi

  local version example
  version="$(current_version)"
  example="$INSTALL_DIR/$version/config.example.yaml"

  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.yaml" "$INSTALL_DIR/config.yaml"
    log_info "Copied config.yaml from source"
  elif [ -f "$example" ]; then
    cp "$example" "$INSTALL_DIR/config.yaml"
    log_warning "Created config.yaml from example -- edit it before relying on the service"
  else
    log_warning "No config.yaml or example available; you must create $INSTALL_DIR/config.yaml manually"
  fi
}

# ===== systemd =====
create_systemd_service() {
  mkdir -p "$(dirname "$SERVICE_FILE")"
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=CLIProxyAPI Service
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME} --config ${INSTALL_DIR}/config.yaml
Restart=always
RestartSec=10
Environment=HOME=${HOME}

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME" >/dev/null 2>&1 || true
  log_success "Installed unit: $SERVICE_FILE"
}

# ===== Version cleanup =====
cleanup_old_versions() {
  local current; current="$(current_version)"
  local total
  total="$(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name 'config_backup' | wc -l)"
  [ "$total" -le "$KEEP_VERSIONS" ] && return 0

  local drop=$(( total - KEEP_VERSIONS ))
  while IFS= read -r dir; do
    local name; name="$(basename "$dir")"
    [ "$name" = "$current" ] && continue
    rm -rf "$dir"
    log_info "Removed old version: $name"
  done < <(find "$INSTALL_DIR" -mindepth 1 -maxdepth 1 -type d ! -name 'config_backup' | sort -V | head -n "$drop")
}

# ===== Service control =====
start_service()   { systemctl --user start   "$SERVICE_NAME"; log_success "Started"; }
stop_service()    { systemctl --user stop    "$SERVICE_NAME" 2>/dev/null || true; log_success "Stopped"; }
restart_service() { systemctl --user restart "$SERVICE_NAME"; log_success "Restarted"; }
service_status()  { systemctl --user status  "$SERVICE_NAME" --no-pager || true; }
service_logs()    { journalctl --user -u "$SERVICE_NAME" -f; }

# ===== API key =====
generate_api_key() {
  local chars='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
  local out='sk-'
  for ((i=0; i<45; i++)); do
    out+="${chars:RANDOM%${#chars}:1}"
  done
  echo "$out"
}

# ===== Commands =====
cmd_install() {
  check_dependencies
  log_step "Installing CLIProxyAPI to $INSTALL_DIR"

  if is_service_running; then
    log_info "Stopping running service..."
    stop_service
  fi

  if is_installed; then backup_config; fi

  mkdir -p "$INSTALL_DIR"
  if [ -n "$BIN_URL" ]; then
    install_from_binary
  else
    ensure_source
    build_from_source
  fi
  setup_config
  create_systemd_service
  cleanup_old_versions
  start_service

  log_success "Install complete. Version: $(current_version)"
  log_info "Status:  $0 status"
  log_info "Logs:    $0 logs"
}

cmd_status() {
  if ! is_installed; then
    log_warning "Not installed (no $INSTALL_DIR/version.txt)"
    return
  fi
  log_info "Install dir:    $INSTALL_DIR"
  log_info "Version:        $(current_version)"
  log_info "Unit file:      $SERVICE_FILE"
  log_info "Active:         $(is_service_running && echo yes || echo no)"
  echo
  service_status
}

cmd_uninstall() {
  read -r -p "This removes $INSTALL_DIR and $SERVICE_FILE. Continue? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) log_info "Cancelled"; exit 0 ;;
  esac
  stop_service
  systemctl --user disable "$SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$SERVICE_FILE"
  systemctl --user daemon-reload
  rm -rf "$INSTALL_DIR"
  log_success "Uninstalled"
}

usage() {
  cat <<EOF
Usage: $0 <command>

Commands:
  install, upgrade   Build from source and (re)install     [default]
  start              Start the systemd --user service
  stop               Stop the service
  restart            Restart the service
  status             Show install and service status
  logs               Follow service logs (journalctl)
  generate-key       Print a new sk- prefixed API key
  uninstall          Remove install dir and systemd unit
  -h, --help         Show this help

Env:
  CLIPROXY_INSTALL_DIR   Override install dir (default: \$HOME/cliproxyapi)

  -- Binary-download mode (DEFAULT: pulls release for current arch) --
  CLIPROXY_BIN_VERSION   Release tag (default: v7.1.17)
  CLIPROXY_BIN_URL       Override binary URL; set EMPTY to use source build
  CLIPROXY_CFG_URL       Override config.example.yaml URL
  CLIPROXY_AUTH_HEADER   Optional HTTP header for auth, e.g.
                         "Authorization: token ghp_xxx"

  -- Source-build mode (set CLIPROXY_BIN_URL= to enable) --
  CLIPROXY_REPO_URL      Git repo to clone when no local source
                         (default: https://github.com/asdwsxzc123/cpa.git)
  CLIPROXY_REPO_REF      Tag / branch / commit to check out (default: v7.1.17)
  CLIPROXY_WORK_DIR      Where to clone source (default: \$HOME/.cache/cliproxyapi-src)
EOF
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install|upgrade) cmd_install ;;
    start)           start_service ;;
    stop)            stop_service ;;
    restart)         restart_service ;;
    status)          cmd_status ;;
    logs)            service_logs ;;
    generate-key)    generate_api_key ;;
    uninstall)       cmd_uninstall ;;
    -h|--help|help)  usage ;;
    *) log_error "Unknown command: $cmd"; usage; exit 1 ;;
  esac
}

main "$@"
