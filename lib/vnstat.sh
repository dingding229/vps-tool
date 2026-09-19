#!/usr/bin/env bash

VNSTAT_STATE_FILE="${VNSTAT_STATE_FILE:-${APP_STATE_DIR}/vnstat.conf}"

validate_network_interface() {
    local interface="${1:-}"
    [[ -n "$interface" && "$interface" =~ ^[[:alnum:]_.:@-]+$ && "$interface" != *'/'* ]]
}

detect_primary_network_interface() {
    local interface=""
    if command_exists ip; then
        interface="$(ip -o route show default 2>/dev/null | awk '{print $5; exit}')"
        if [[ -z "$interface" ]]; then
            interface="$(ip -o link show 2>/dev/null | awk -F': ' '$2 != "lo" {sub(/@.*/, "", $2); print $2; exit}')"
        fi
    fi
    if [[ -z "$interface" && -d /sys/class/net ]]; then
        interface="$(find /sys/class/net -mindepth 1 -maxdepth 1 ! -name lo -printf '%f\n' 2>/dev/null | sort | head -n 1)"
    fi
    validate_network_interface "$interface" || return 1
    printf '%s' "$interface"
}

vnstat_db_interfaces() {
    command_exists vnstat || return 1
    vnstat --dbiflist 1 2>/dev/null | sed '/^[[:space:]]*$/d'
}

vnstat_db_interfaces_inline() {
    local interfaces
    interfaces="$(vnstat_db_interfaces 2>/dev/null | paste -sd, - | sed 's/,/, /g' || true)"
    printf '%s' "${interfaces:-暂无}"
}

vnstat_interface_is_monitored() {
    local interface="$1"
    validate_network_interface "$interface" || return 1
    vnstat_db_interfaces | grep -Fxq -- "$interface"
}

read_vnstat_state_interface() {
    local state_file="${VNSTAT_STATE_FILE:-${APP_STATE_DIR}/vnstat.conf}"
    [[ -r "$state_file" ]] || return 1
    awk -F= '$1=="INTERFACE" {print substr($0, index($0, "=") + 1); exit}' "$state_file"
}

save_vnstat_state() {
    local interface="$1" state_file="${VNSTAT_STATE_FILE:-${APP_STATE_DIR}/vnstat.conf}"
    validate_network_interface "$interface" || return 1
    mkdir -p "$(dirname "$state_file")"
    cat > "$state_file" <<EOF_STATE
INTERFACE=${interface}
UPDATED_AT=$(beijing_iso)
EOF_STATE
    chmod 600 "$state_file"
}

get_vnstat_interface() {
    local interface=""
    interface="$(read_vnstat_state_interface 2>/dev/null || true)"
    if [[ -n "$interface" ]] && vnstat_interface_is_monitored "$interface"; then
        printf '%s' "$interface"
        return 0
    fi

    interface="$(detect_primary_network_interface 2>/dev/null || true)"
    if [[ -n "$interface" ]] && vnstat_interface_is_monitored "$interface"; then
        printf '%s' "$interface"
        return 0
    fi

    interface="$(vnstat_db_interfaces 2>/dev/null | head -n 1 || true)"
    validate_network_interface "$interface" || return 1
    printf '%s' "$interface"
}

install_vnstat_packages() {
    log_info "正在更新软件包索引..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$APP_LOG_FILE" 2>&1 \
        || { log_error "apt-get update 失败，详情见 ${APP_LOG_FILE}"; return 1; }
    log_info "正在安装 vnStat 流量监控..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y vnstat python3 >> "$APP_LOG_FILE" 2>&1 \
        || { log_error "vnStat 安装失败，详情见 ${APP_LOG_FILE}"; return 1; }
    log_success "vnStat 已安装"
}

ensure_vnstat_interface() {
    local interface="$1"
    validate_network_interface "$interface" || { log_error "网络接口名称无效"; return 1; }
    [[ -d "/sys/class/net/${interface}" ]] \
        || { log_error "网络接口 ${interface} 不存在"; return 1; }

    if vnstat_interface_is_monitored "$interface"; then
        log_success "vnStat 已监控接口 ${interface}"
        return 0
    fi

    log_info "正在将 ${interface} 加入 vnStat 数据库..."
    if ! vnstat --add -i "$interface" >> "$APP_LOG_FILE" 2>&1; then
        # 部分发行版的守护进程会在安装后自动创建接口，再检查一次以避免误报。
        vnstat_interface_is_monitored "$interface" \
            || { log_error "无法将 ${interface} 加入 vnStat 数据库，详情见 ${APP_LOG_FILE}"; return 1; }
    fi
    log_success "已开始监控接口 ${interface}"
}

configure_vnstat_interactive() {
    ui_header
    ui_title "vnStat 流量监控安装"
    check_supported_os

    local detected interface installed="未安装"
    detected="$(get_vnstat_interface 2>/dev/null || detect_primary_network_interface 2>/dev/null || true)"
    [[ -n "$detected" ]] || { log_error "未检测到可用网络接口"; return 1; }
    command_exists vnstat && installed="已安装"

    ui_section "01" "当前环境"
    ui_kv "安装状态" "$installed"
    ui_kv "推荐接口" "${C_CYAN}${detected}${C_RESET}"
    if command_exists vnstat; then
        ui_kv "服务状态" "$(ui_state "$(systemctl is-active vnstat 2>/dev/null || true)")"
        ui_kv "已监控接口" "$(vnstat_db_interfaces_inline)"
    fi

    ui_section "02" "安装参数"
    interface="$(prompt_value '需要监控的网络接口' "$detected")" || return 1
    validate_network_interface "$interface" || { log_error "网络接口名称无效"; return 1; }
    [[ -d "/sys/class/net/${interface}" ]] || { log_error "网络接口 ${interface} 不存在"; return 1; }
    ui_kv "目标接口" "$interface"
    ui_kv "采集方式" "vnStat 后台服务"
    ui_kv "数据展示" "字节自动换算，时间统一为${APP_TIMEZONE_LABEL:-北京时间}"
    printf '\n'
    confirm "确认安装并启用 vnStat" "Y" || { log_warn "已取消 vnStat 安装"; return 0; }

    command_exists vnstat || install_vnstat_packages || return 1
    ensure_vnstat_interface "$interface" || return 1
    systemctl enable --now vnstat >> "$APP_LOG_FILE" 2>&1 \
        || { log_error "vnStat 服务启用失败，详情见 ${APP_LOG_FILE}"; return 1; }
    systemctl restart vnstat >> "$APP_LOG_FILE" 2>&1 \
        || { log_error "vnStat 服务重启失败，详情见 ${APP_LOG_FILE}"; return 1; }
    sleep 1
    service_active vnstat || { log_error "vnStat 服务未正常运行"; return 1; }
    save_vnstat_state "$interface" || return 1

    log_success "vnStat 已启用，正在监控 ${interface}"
    log_warn "新安装后需要等待采集；vnStat 不会生成安装前的历史流量"
}

# 将 vnStat JSON 转换成中文表格。输入必须从标准输入传入，禁止直接展示原始 JSON。
render_vnstat_json() {
    local view="${1:-summary}" requested_interface="${2:-}" 
    python3 - "$view" "$requested_interface" "${APP_TIMEZONE:-Asia/Shanghai}" \
        "$C_GREEN" "$C_CYAN" "$C_BOLD" "$C_DIM" "$C_YELLOW" "$C_RED" "$C_RESET" 3<&0 <<'PY_VNSTAT'
import datetime as dt
import json
import os
import sys
import unicodedata
from zoneinfo import ZoneInfo

(view, requested, timezone_name, green, cyan, bold, dim, yellow, red, reset) = sys.argv[1:]
raw = os.fdopen(3).read()
try:
    payload = json.loads(raw)
except Exception:
    print(f"{red}✖ ERROR{reset} 无法解析 vnStat 数据")
    raise SystemExit(1)

if not isinstance(payload, dict):
    print(f"{red}✖ ERROR{reset} vnStat 返回了不支持的数据结构")
    raise SystemExit(1)
interfaces = payload.get("interfaces")
if not isinstance(interfaces, list) or not interfaces or not all(isinstance(item, dict) for item in interfaces):
    print(f"{yellow}▲ WARN{reset} vnStat 数据库中没有可用接口")
    raise SystemExit(2)

interface = next((item for item in interfaces if item.get("name") == requested), interfaces[0])
traffic = interface.get("traffic") or {}
try:
    zone = ZoneInfo(timezone_name)
except Exception:
    zone = dt.timezone(dt.timedelta(hours=8))

def number(value):
    try:
        return max(0, int(value))
    except (TypeError, ValueError):
        return 0

def size(value):
    amount = float(number(value))
    units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
    unit = units[0]
    for candidate in units:
        unit = candidate
        if amount < 1024 or candidate == units[-1]:
            break
        amount /= 1024
    if unit == "B":
        return f"{int(amount)} {unit}"
    return f"{amount:.2f} {unit}"

def stamp(record):
    try:
        return int(record.get("timestamp", 0))
    except (TypeError, ValueError, AttributeError):
        return 0

def bj_time(record, pattern):
    timestamp = stamp(record)
    if timestamp > 0:
        return dt.datetime.fromtimestamp(timestamp, zone).strftime(pattern)
    date = (record or {}).get("date") or {}
    time = (record or {}).get("time") or {}
    values = {
        "year": number(date.get("year")) or 1970,
        "month": number(date.get("month")) or 1,
        "day": number(date.get("day")) or 1,
        "hour": number(time.get("hour")),
        "minute": number(time.get("minute")),
    }
    try:
        return dt.datetime(**values, tzinfo=zone).strftime(pattern)
    except (ValueError, TypeError):
        return "未知"

def visible_width(text):
    return sum(0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1 for char in text)

def pad(text, width):
    return text + " " * max(0, width - visible_width(text))

def kv(label, value):
    print(f"  {dim}{pad(label, 18)}{reset}  {value}")

def latest(rows):
    rows = [row for row in (rows or []) if isinstance(row, dict)]
    return max(rows, key=stamp) if rows else None

def row_values(row):
    rx, tx = number(row.get("rx")), number(row.get("tx"))
    return rx, tx, rx + tx

def warn_empty():
    print(f"{yellow}▲ WARN{reset} vnStat 已开始采集，但当前还没有足够的历史流量数据")

if view == "summary":
    total = traffic.get("total") or {}
    updated = interface.get("updated") or {}
    created = interface.get("created") or {}
    rx, tx = number(total.get("rx")), number(total.get("tx"))
    kv("网络接口", f"{bold}{cyan}{interface.get('name', '未知')}{reset}")
    kv("数据库更新时间", f"{bj_time(updated, '%Y-%m-%d %H:%M:%S')} 北京时间")
    kv("开始采集时间", f"{bj_time(created, '%Y-%m-%d')} 北京时间")
    kv("累计接收", f"{green}{size(rx)}{reset}")
    kv("累计发送", f"{cyan}{size(tx)}{reset}")
    kv("累计流量", f"{bold}{size(rx + tx)}{reset}")
    daily = latest(traffic.get("day"))
    monthly = latest(traffic.get("month"))
    if daily:
        drx, dtx, dtotal = row_values(daily)
        kv("最新日统计", f"{bj_time(daily, '%Y-%m-%d')}  接收 {size(drx)} / 发送 {size(dtx)} / 合计 {bold}{size(dtotal)}{reset}")
    if monthly:
        mrx, mtx, mtotal = row_values(monthly)
        kv("最新月统计", f"{bj_time(monthly, '%Y-%m')}  接收 {size(mrx)} / 发送 {size(mtx)} / 合计 {bold}{size(mtotal)}{reset}")
    if not daily and not monthly:
        print()
        warn_empty()
    raise SystemExit(0)

settings = {
    "today": ("day", "%Y-%m-%d", "日期"),
    "hour": ("hour", "%Y-%m-%d %H:%M", "北京时间"),
    "day": ("day", "%Y-%m-%d", "日期"),
    "month": ("month", "%Y-%m", "月份"),
    "top": ("top", "%Y-%m-%d", "日期"),
}
if view not in settings:
    print(f"{red}✖ ERROR{reset} 不支持的流量视图：{view}")
    raise SystemExit(1)

key, pattern, first_title = settings[view]
rows = [row for row in (traffic.get(key) or []) if isinstance(row, dict)]
if view == "today":
    today = dt.datetime.now(zone).strftime("%Y-%m-%d")
    rows = [row for row in rows if bj_time(row, "%Y-%m-%d") == today]
if not rows:
    warn_empty()
    raise SystemExit(0)
if view != "top":
    rows.sort(key=stamp, reverse=True)

first_width = 18 if view == "hour" else 12
print(f"  {bold}{pad(first_title, first_width)}  {pad('接收', 13)}  {pad('发送', 13)}  合计{reset}")
print(f"  {dim}{'─' * (first_width + 46)}{reset}")
for row in rows:
    rx, tx, total = row_values(row)
    period = bj_time(row, pattern)
    print(f"  {pad(period, first_width)}  {green}{pad(size(rx), 13)}{reset}  {cyan}{pad(size(tx), 13)}{reset}  {bold}{size(total)}{reset}")
PY_VNSTAT
}

vnstat_json_report() {
    local interface="$1" view="$2" json=""
    case "$view" in
        summary) json="$(vnstat -i "$interface" --json s 2>> "$APP_LOG_FILE")" ;;
        today) json="$(vnstat -i "$interface" --json d 2 2>> "$APP_LOG_FILE")" ;;
        hour) json="$(vnstat -i "$interface" --json h "${VNSTAT_HOUR_LIMIT:-24}" 2>> "$APP_LOG_FILE")" ;;
        day) json="$(vnstat -i "$interface" --json d "${VNSTAT_DAY_LIMIT:-30}" 2>> "$APP_LOG_FILE")" ;;
        month) json="$(vnstat -i "$interface" --json m "${VNSTAT_MONTH_LIMIT:-12}" 2>> "$APP_LOG_FILE")" ;;
        top) json="$(vnstat -i "$interface" --json t "${VNSTAT_TOP_LIMIT:-10}" 2>> "$APP_LOG_FILE")" ;;
        *) log_error "未知的 vnStat 查询类型：${view}"; return 1 ;;
    esac
    [[ -n "$json" ]] || { log_error "未能读取 ${interface} 的 vnStat 数据"; return 1; }
    render_vnstat_json "$view" "$interface" <<< "$json"
}

print_vnstat_status() {
    if ! command_exists vnstat; then
        ui_kv "安装状态" "${C_YELLOW}▲ 未安装${C_RESET}"
        return 1
    fi

    local interface interfaces version service_state enabled_state json metrics updated latest_total
    version="$(vnstat --version 2>/dev/null | awk 'NR==1 {print $2; exit}')"
    service_state="$(systemctl is-active vnstat 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled vnstat 2>/dev/null || true)"
    interfaces="$(vnstat_db_interfaces 2>/dev/null | paste -sd, - | sed 's/,/, /g' || true)"
    interface="$(get_vnstat_interface 2>/dev/null || true)"

    ui_kv "安装版本" "${version:-未知}"
    ui_kv "服务状态" "$(ui_state "${service_state:-unknown}")"
    ui_kv "开机启动" "$(ui_state "${enabled_state:-unknown}")"
    ui_kv "监控接口" "${interfaces:-暂无}"
    ui_kv "默认接口" "${interface:-未选择}"

    [[ -n "$interface" ]] || return 1
    json="$(vnstat -i "$interface" --json s 2>/dev/null || true)"
    [[ -n "$json" ]] || { ui_kv "流量数据" "${C_YELLOW}▲ 暂不可用${C_RESET}"; return 1; }
    metrics="$(python3 - "${APP_TIMEZONE:-Asia/Shanghai}" 3<<< "$json" <<'PY_STATUS'
import datetime as dt, json, os, sys
from zoneinfo import ZoneInfo
try:
    data = json.load(os.fdopen(3))
    iface = data["interfaces"][0]
    updated = int((iface.get("updated") or {}).get("timestamp", 0))
    days = (iface.get("traffic") or {}).get("day") or []
    latest = max(days, key=lambda row: int(row.get("timestamp", 0))) if days else None
    update_text = dt.datetime.fromtimestamp(updated, ZoneInfo(sys.argv[1])).strftime("%Y-%m-%d %H:%M:%S") if updated else "未知"
    total = int(latest.get("rx", 0)) + int(latest.get("tx", 0)) if latest else -1
    print(update_text)
    print(total)
except Exception:
    raise SystemExit(1)
PY_STATUS
)" || { ui_kv "流量数据" "${C_YELLOW}▲ 解析失败${C_RESET}"; return 1; }
    updated="$(sed -n '1p' <<< "$metrics")"
    latest_total="$(sed -n '2p' <<< "$metrics")"
    ui_kv "数据更新时间" "${updated} ${APP_TIMEZONE_LABEL:-北京时间}"
    if [[ "$latest_total" =~ ^[0-9]+$ ]]; then
        ui_kv "最新日流量" "$(vnstat_format_bytes "$latest_total")"
    else
        ui_kv "最新日流量" "${C_DIM}等待采集${C_RESET}"
    fi
}

vnstat_format_bytes() {
    local bytes="${1:-0}"
    python3 - "$bytes" <<'PY_BYTES'
import sys
try:
    value = max(0, int(sys.argv[1]))
except ValueError:
    value = 0
amount = float(value)
units = ("B", "KiB", "MiB", "GiB", "TiB", "PiB")
for unit in units:
    if amount < 1024 or unit == units[-1]:
        print(f"{int(amount)} {unit}" if unit == "B" else f"{amount:.2f} {unit}", end="")
        break
    amount /= 1024
PY_BYTES
}

verify_vnstat() {
    local interface json
    command_exists vnstat || return 2
    service_active vnstat || return 1
    interface="$(get_vnstat_interface 2>/dev/null || true)"
    [[ -n "$interface" ]] || return 1
    vnstat_interface_is_monitored "$interface" || return 1
    json="$(vnstat -i "$interface" --json s 2>/dev/null || true)"
    [[ -n "$json" ]] || return 1
    python3 -c 'import json,sys; data=json.load(sys.stdin); assert data.get("interfaces")' <<< "$json" >/dev/null 2>&1
}

change_vnstat_interface_interactive() {
    local current detected interface
    current="$(get_vnstat_interface 2>/dev/null || true)"
    detected="$(detect_primary_network_interface 2>/dev/null || true)"
    ui_section "01" "接口选择"
    ui_kv "当前接口" "${current:-未选择}"
    ui_kv "系统主接口" "${detected:-未检测到}"
    ui_kv "数据库接口" "$(vnstat_db_interfaces_inline)"
    interface="$(prompt_value '新的默认监控接口' "${current:-$detected}")" || return 1
    validate_network_interface "$interface" || { log_error "网络接口名称无效"; return 1; }
    [[ -d "/sys/class/net/${interface}" ]] || { log_error "网络接口 ${interface} 不存在"; return 1; }
    if ! vnstat_interface_is_monitored "$interface"; then
        confirm "${interface} 尚未监控，是否加入 vnStat 数据库" "Y" \
            || { log_warn "已取消接口切换"; return 0; }
        ensure_vnstat_interface "$interface" || return 1
        systemctl restart vnstat >> "$APP_LOG_FILE" 2>&1 || return 1
    fi
    save_vnstat_state "$interface"
    log_success "默认流量查询接口已切换为 ${interface}"
}

vnstat_query_page() {
    local view="$1" title="$2" interface
    ui_header
    ui_title "$title"
    if ! command_exists vnstat; then
        log_warn "vnStat 尚未安装，请先选择安装功能"
        return 1
    fi
    interface="$(get_vnstat_interface 2>/dev/null || true)"
    [[ -n "$interface" ]] || { log_error "vnStat 数据库中没有可查询的网络接口"; return 1; }
    ui_section "01" "查询信息"
    ui_kv "网络接口" "$interface"
    ui_kv "显示时区" "${APP_TIMEZONE_LABEL:-北京时间}（${APP_TIMEZONE:-Asia/Shanghai}）"
    ui_section "02" "格式化流量数据"
    vnstat_json_report "$interface" "$view"
}

vnstat_menu() {
    local choice
    while true; do
        ui_header
        ui_title "vnStat 流量中心"
        ui_menu_group "流量查询"
        ui_menu_item 1 "流量总览" "累计 / 最新日月统计"
        ui_menu_item 2 "今日流量" "按北京时间统计"
        ui_menu_item 3 "最近 24 小时" "按小时格式化"
        ui_menu_item 4 "最近 30 天" "按日期格式化"
        ui_menu_item 5 "最近 12 个月" "按月份格式化"
        ui_menu_item 6 "流量最高日期" "Top 10"

        ui_menu_group "配置与状态"
        ui_menu_item 7 "安装或修复 vnStat" "启用服务 / 选择接口"
        ui_menu_item 8 "切换监控接口" "更改默认查询接口"
        ui_menu_item 9 "查看 vnStat 状态" "服务 / 数据库"

        ui_menu_group "其他"
        ui_menu_item 0 "返回主菜单"
        printf '\n'
        choice="$(select_number '请选择功能' 0 9 1)" || return
        case "$choice" in
            1) vnstat_query_page summary "vnStat 流量总览"; pause_screen ;;
            2) vnstat_query_page today "今日流量"; pause_screen ;;
            3) vnstat_query_page hour "最近 24 小时流量"; pause_screen ;;
            4) vnstat_query_page day "最近 30 天流量"; pause_screen ;;
            5) vnstat_query_page month "最近 12 个月流量"; pause_screen ;;
            6) vnstat_query_page top "流量最高日期"; pause_screen ;;
            7) configure_vnstat_interactive; pause_screen ;;
            8)
                ui_header; ui_title "切换 vnStat 监控接口"
                if command_exists vnstat; then change_vnstat_interface_interactive; else log_warn "vnStat 尚未安装"; fi
                pause_screen
                ;;
            9)
                ui_header; ui_title "vnStat 服务状态"; ui_section "01" "运行状态"
                print_vnstat_status || true; pause_screen
                ;;
            0) return 0 ;;
        esac
    done
}
