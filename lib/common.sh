#!/usr/bin/env bash

# 颜色仅在终端中启用
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_MAGENTA=$'\033[35m'; C_CYAN=$'\033[36m'; C_WHITE=$'\033[37m'
    BG_BLUE=$'\033[44m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
    C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_WHITE=""; BG_BLUE=""
fi

UI_WIDTH=68

repeat_char() {
    local char="$1" count="$2" out=""
    printf -v out '%*s' "$count" ''
    printf '%s' "${out// /$char}"
}

clear_screen() {
    if [[ -t 1 && "${VPS_TOOL_NO_CLEAR:-0}" != "1" ]]; then
        printf '\033[2J\033[H'
    fi
}

ui_rule() {
    printf '%s' "$C_CYAN"
    repeat_char '─' "$UI_WIDTH"
    printf '%s\n' "$C_RESET"
}

ui_header() {
    clear_screen
    printf '\n%s%s' "$C_BOLD" "$C_CYAN"
    printf '╭'; repeat_char '─' "$UI_WIDTH"; printf '╮\n'
    printf '│                         V P S   T O O L                          │\n'
    printf '╰'; repeat_char '─' "$UI_WIDTH"; printf '╯%s\n' "$C_RESET"
    printf '  %s安全初始化 · 可验证 · 可回滚%s' "$C_BOLD" "$C_RESET"
    printf '    %sv%s · %s%s\n\n' "$C_DIM" "$APP_VERSION" "$(date '+%Y-%m-%d %H:%M:%S')" "$C_RESET"
}

ui_title() {
    printf '\n%s%s▌ %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
    ui_rule
}

ui_menu_item() {
    local key="$1" label="$2" note="${3:-}"
    printf '  %s%s[%s]%s %-28s' "$C_BOLD" "$C_GREEN" "$key" "$C_RESET" "$label"
    [[ -n "$note" ]] && printf ' %s%s%s' "$C_DIM" "$note" "$C_RESET"
    printf '\n'
}

log_line() {
    local level="$1" color="$2" symbol="$3" message="$4"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s%s %s%s %s\n' "$color" "$symbol" "$level" "$C_RESET" "$message"
    if [[ -n "${APP_LOG_FILE:-}" && -d "$(dirname "$APP_LOG_FILE")" ]]; then
        printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" >> "$APP_LOG_FILE" 2>/dev/null || true
    fi
}

log_info()    { log_line INFO "$C_BLUE" '●' "$*"; }
log_success() { log_line OK "$C_GREEN" '✔' "$*"; }
log_warn()    { log_line WARN "$C_YELLOW" '▲' "$*"; }
log_error()   { log_line ERROR "$C_RED" '✖' "$*"; }

die() {
    log_error "$*"
    exit 1
}

pause_screen() {
    printf '\n%s按 Enter 键返回...%s' "$C_DIM" "$C_RESET"
    read -r _ || true
}

confirm() {
    local prompt="$1" default="${2:-N}" answer suffix
    if [[ "$default" =~ ^[Yy]$ ]]; then suffix='[Y/n]'; else suffix='[y/N]'; fi
    printf '%s?%s %s %s ' "$C_YELLOW" "$C_RESET" "$prompt" "$suffix" >&2
    read -r answer || return 1
    answer="${answer:-$default}"
    [[ "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]
}

prompt_value() {
    local prompt="$1" default="${2:-}" value
    if [[ -n "$default" ]]; then
        printf '%s›%s %s %s[%s]%s: ' "$C_CYAN" "$C_RESET" "$prompt" "$C_DIM" "$default" "$C_RESET" >&2
    else
        printf '%s›%s %s: ' "$C_CYAN" "$C_RESET" "$prompt" >&2
    fi
    read -r value || return 1
    printf '%s' "${value:-$default}"
}

select_number() {
    local prompt="$1" min="$2" max="$3" default="${4:-}" value
    while true; do
        value="$(prompt_value "$prompt" "$default")" || return 1
        if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= min && value <= max )); then
            printf '%s' "$value"
            return 0
        fi
        log_warn "请输入 ${min}-${max} 之间的数字"
    done
}

validate_port() {
    local port="$1"
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_ip() {
    local ip="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$ip" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ipaddress.ip_address(sys.argv[1])
PY
        return $?
    fi
    [[ "$ip" =~ ^[0-9a-fA-F:.]+$ ]]
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

require_root() {
    (( EUID == 0 )) || die "请使用 root 权限运行：sudo bash vps-init.sh"
}

initialize_runtime() {
    mkdir -p "$APP_ETC_DIR" "$APP_STATE_DIR" "$APP_BACKUP_DIR" "$APP_LOG_DIR" "$(dirname "$APP_LOCK_FILE")"
    touch "$APP_LOG_FILE"
    chmod 700 "$APP_ETC_DIR" "$APP_STATE_DIR" "$APP_BACKUP_DIR"
    chmod 600 "$APP_LOG_FILE"
}

acquire_lock() {
    command_exists flock || return 0
    exec 9>"$APP_LOCK_FILE"
    flock -n 9 || die "另一个 vps-tool 实例正在运行"
}

create_backup_dir() {
    local timestamp path
    timestamp="$(date '+%Y%m%d-%H%M%S')"
    path="${APP_BACKUP_DIR}/${timestamp}"
    mkdir -p "$path"
    chmod 700 "$path"
    printf '%s' "$path"
}

run_logged() {
    printf '[%s] [CMD] ' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$APP_LOG_FILE"
    printf '%q ' "$@" >> "$APP_LOG_FILE"
    printf '\n' >> "$APP_LOG_FILE"
    "$@" 2>&1 | tee -a "$APP_LOG_FILE"
    return "${PIPESTATUS[0]}"
}

service_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

service_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}
