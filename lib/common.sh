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


detect_system_timezone() {
    local detected=""
    if command -v timedatectl >/dev/null 2>&1; then
        detected="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
    fi
    if [[ -z "$detected" && -r /etc/timezone ]]; then
        detected="$(head -n 1 /etc/timezone 2>/dev/null || true)"
    fi
    if [[ -z "$detected" && -L /etc/localtime ]]; then
        detected="$(readlink -f /etc/localtime 2>/dev/null || true)"
        detected="${detected#*/zoneinfo/}"
    fi
    [[ -n "$detected" ]] || detected="UTC"
    printf '%s' "$detected"
}

# 保存服务器原时区用于解析无偏移量的系统日志；工具自身统一以北京时间显示。
APP_SOURCE_TIMEZONE="${APP_SOURCE_TIMEZONE:-$(detect_system_timezone)}"
export APP_SOURCE_TIMEZONE
export TZ="${APP_TIMEZONE:-Asia/Shanghai}"

beijing_date() {
    TZ="${APP_TIMEZONE:-Asia/Shanghai}" date "$@"
}

source_timezone_date() {
    TZ="${APP_SOURCE_TIMEZONE:-UTC}" date "$@"
}

beijing_now() {
    beijing_date '+%Y-%m-%d %H:%M:%S'
}

beijing_iso() {
    beijing_date '+%Y-%m-%dT%H:%M:%S%z'
}

beijing_compact() {
    beijing_date '+%Y%m%d-%H%M%S'
}

beijing_datetime() {
    local input="$1" source_timezone="${2:-${APP_SOURCE_TIMEZONE:-UTC}}"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$input" "${APP_TIMEZONE:-Asia/Shanghai}" "$source_timezone" <<'PY_TIME'
import datetime as dt
import re, sys
from zoneinfo import ZoneInfo

raw, target_name, source_name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    normalized = raw.strip().replace('Z', '+00:00')
    match = re.match(
        r'^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:[.,]\d+)?([+-]\d{2}:?\d{2})?$',
        normalized,
    )
    if not match:
        raise ValueError('unsupported timestamp')
    date_part, time_part, offset = match.groups()
    parsed = dt.datetime.strptime(f'{date_part} {time_part}', '%Y-%m-%d %H:%M:%S')
    if offset:
        clean = offset if ':' in offset else offset[:3] + ':' + offset[3:]
        sign = 1 if clean[0] == '+' else -1
        zone = dt.timezone(sign * dt.timedelta(hours=int(clean[1:3]), minutes=int(clean[4:6])))
    else:
        zone = ZoneInfo(source_name)
    parsed = parsed.replace(tzinfo=zone)
    print(parsed.astimezone(ZoneInfo(target_name)).strftime('%Y-%m-%d %H:%M:%S'), end='')
except Exception:
    print(raw, end='')
PY_TIME
    elif date -d '@0' '+%s' >/dev/null 2>&1; then
        local epoch
        if [[ "$input" =~ (Z|[+-][0-9]{2}:?[0-9]{2})$ ]]; then
            epoch="$(date -d "$input" '+%s' 2>/dev/null)" || { printf '%s' "$input"; return; }
        else
            epoch="$(TZ="$source_timezone" date -d "$input" '+%s' 2>/dev/null)" \
                || { printf '%s' "$input"; return; }
        fi
        TZ="${APP_TIMEZONE:-Asia/Shanghai}" date -d "@${epoch}" '+%Y-%m-%d %H:%M:%S'
    else
        printf '%s' "$input"
    fi
}

UI_WIDTH=68
UI_LABEL_WIDTH=16

ui_update_width() {
    local columns=70
    if command -v tput >/dev/null 2>&1 && [[ -t 1 ]]; then
        columns="$(tput cols 2>/dev/null || printf '70')"
    fi
    [[ "$columns" =~ ^[0-9]+$ ]] || columns=70
    if (( columns > 116 )); then
        UI_WIDTH=112
    elif (( columns >= 44 )); then
        UI_WIDTH=$((columns - 4))
    else
        UI_WIDTH=40
    fi
}

repeat_char() {
    local char="$1" count="$2" out=""
    printf -v out '%*s' "$count" ''
    printf '%s' "${out// /$char}"
}

ui_pad_right() {
    local text="$1" width="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$text" "$width" <<'PY_WIDTH'
import re, sys, unicodedata
text, width = sys.argv[1], int(sys.argv[2])
plain = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text)
def cell_width(value):
    total = 0
    for char in value:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
    return total
sys.stdout.write(text + ' ' * max(0, width - cell_width(plain)))
PY_WIDTH
    else
        printf '%-*s' "$width" "$text"
    fi
}

ui_center() {
    local text="$1" width="$2"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$text" "$width" <<'PY_CENTER'
import re, sys, unicodedata
text, width = sys.argv[1], int(sys.argv[2])
plain = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', text)
def cell_width(value):
    total = 0
    for char in value:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
    return total
used = cell_width(plain)
left = max(0, (width - used) // 2)
right = max(0, width - used - left)
sys.stdout.write(' ' * left + text + ' ' * right)
PY_CENTER
    else
        printf '%*s' "$width" "$text"
    fi
}

ui_columns() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$@" <<'PY_COLUMNS'
import re, sys, unicodedata
args = sys.argv[1:]
def cell_width(value):
    value = re.sub(r'\x1b\[[0-9;?]*[ -/]*[@-~]', '', value)
    total = 0
    for char in value:
        if unicodedata.combining(char):
            continue
        total += 2 if unicodedata.east_asian_width(char) in ('W', 'F') else 1
    return total
cells = []
for index in range(0, len(args), 2):
    text, width = args[index], int(args[index + 1])
    cells.append(text + ' ' * max(0, width - cell_width(text)))
sys.stdout.write('  '.join(cells))
PY_COLUMNS
    else
        while (( $# >= 2 )); do
            printf '%-*s' "$2" "$1"
            shift 2
            (( $# >= 2 )) && printf '  '
        done
    fi
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
    local title tagline metadata
    ui_update_width
    clear_screen
    title="$(ui_center 'V P S   T O O L' "$UI_WIDTH")"
    tagline="$(ui_center '安全配置 · 状态监控 · 自动回滚' "$UI_WIDTH")"
    metadata="$(ui_center "v${APP_VERSION}  ·  $(beijing_now)  ${APP_TIMEZONE_LABEL:-北京时间}" "$UI_WIDTH")"
    printf '\n%s%s╭' "$C_BOLD" "$C_CYAN"
    repeat_char '─' "$UI_WIDTH"
    printf '╮\n│%s│\n│%s│\n╰' "$title" "$tagline"
    repeat_char '─' "$UI_WIDTH"
    printf '╯%s\n%s%s%s\n' "$C_RESET" "$C_DIM" "$metadata" "$C_RESET"
}

ui_title() {
    printf '\n%s%s▌ %s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
    ui_rule
}

ui_section() {
    local order="$1" title="$2"
    printf '\n%s%s%s%s  %s%s\n' "$C_BOLD" "$C_CYAN" "$order" "$C_RESET" "$C_BOLD" "$title$C_RESET"
    printf '%s' "$C_DIM"
    repeat_char '─' "$UI_WIDTH"
    printf '%s\n' "$C_RESET"
}

ui_subtitle() {
    printf '\n  %s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
}

ui_kv() {
    local label="$1" value="$2" label_padded
    label_padded="$(ui_pad_right "$label" "$UI_LABEL_WIDTH")"
    printf '  %s%s%s  %s\n' "$C_DIM" "$label_padded" "$C_RESET" "$value"
}

ui_state() {
    local state="${1:-unknown}"
    case "$state" in
        active|running|enabled|yes|true)
            printf '%s● %s%s' "$C_GREEN" "$state" "$C_RESET"
            ;;
        inactive|disabled|no|false|failed)
            printf '%s● %s%s' "$C_RED" "$state" "$C_RESET"
            ;;
        *) printf '%s● %s%s' "$C_YELLOW" "$state" "$C_RESET" ;;
    esac
}

ui_expect() {
    local value="${1:-unknown}" expected="$2"
    if [[ "$value" == "$expected" ]]; then
        printf '%s✔ %s%s' "$C_GREEN" "$value" "$C_RESET"
    else
        printf '%s✖ %s%s' "$C_RED" "$value" "$C_RESET"
    fi
}

ui_menu_group() {
    printf '\n  %s%s%s%s\n' "$C_BOLD" "$C_CYAN" "$1" "$C_RESET"
}

ui_menu_item() {
    local key="$1" label="$2" note="${3:-}" key_padded label_padded
    key_padded="$(ui_pad_right "[${key}]" 5)"
    label_padded="$(ui_pad_right "$label" 28)"
    printf '    %s%s%s%s%s' "$C_BOLD" "$C_GREEN" "$key_padded" "$C_RESET" "$label_padded"
    [[ -n "$note" ]] && printf ' %s%s%s' "$C_DIM" "$note" "$C_RESET"
    printf '\n'
}


log_line() {
    local level="$1" color="$2" symbol="$3" message="$4"
    local timestamp
    timestamp="$(beijing_now)"
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
    local prompt="$1" answer
    while true; do
        printf '%s?%s %s %s[Y/n]%s ' \
            "$C_YELLOW" "$C_RESET" "$prompt" "$C_DIM" "$C_RESET" >&2
        read -r answer || return 1
        answer="${answer:-Y}"
        case "$answer" in
            Y|y) return 0 ;;
            N|n) return 1 ;;
            *) log_warn "请输入 Y 或 N；直接回车默认为 Y" >&2 ;;
        esac
    done
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
    timestamp="$(beijing_compact)"
    path="${APP_BACKUP_DIR}/${timestamp}"
    mkdir -p "$path"
    chmod 700 "$path"
    printf '%s' "$path"
}

run_logged() {
    printf '[%s] [CMD] ' "$(beijing_now)" >> "$APP_LOG_FILE"
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
