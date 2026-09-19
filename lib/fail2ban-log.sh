#!/usr/bin/env bash

FAIL2BAN_LOG_SOURCE="none"

require_fail2ban() {
    command_exists fail2ban-client || { log_warn "Fail2ban 尚未安装"; return 1; }
}

detect_fail2ban_log_source() {
    if [[ -r "$FAIL2BAN_LOG_FILE" ]]; then
        FAIL2BAN_LOG_SOURCE="file"
    elif command_exists journalctl; then
        FAIL2BAN_LOG_SOURCE="journal"
    else
        FAIL2BAN_LOG_SOURCE="none"
        return 1
    fi
}

fail2ban_log_header() {
    printf '  %s%-19s  %-10s  %-12s  %-39s  %s%s\n' \
        "$C_BOLD" "时间" "事件" "Jail" "IP / 对象" "说明" "$C_RESET"
    printf '  %s' "$C_DIM"
    repeat_char '─' 104
    printf '%s\n' "$C_RESET"
    printf '  %s红色：封禁、恢复封禁或异常%s  %s黄色：失败尝试/停止%s  %s绿色：解封/启动%s\n\n' \
        "$C_RED" "$C_RESET" "$C_YELLOW" "$C_RESET" "$C_GREEN" "$C_RESET"
}

fail2ban_clean_message() {
    local message="$1"
    message="${message//$'\033'/}"
    message="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g' <<< "$message")"
    printf '%s' "$message"
}

fail2ban_extract_timestamp() {
    local line="$1"
    if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})[[:space:]]+([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    elif [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2}:[0-9]{2}:[0-9]{2}) ]]; then
        printf '%s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
        printf '%s' '--'
    fi
}

fail2ban_extract_message() {
    local line="$1" message
    if [[ "$line" =~ \]:[[:space:]]+[A-Z]+[[:space:]]+(.*)$ ]]; then
        message="${BASH_REMATCH[1]}"
    elif [[ "$line" =~ fail2ban[^:]*:[[:space:]]+(.*)$ ]]; then
        message="${BASH_REMATCH[1]}"
    else
        message="$line"
    fi
    fail2ban_clean_message "$message"
}

fail2ban_print_row() {
    local color="$1" timestamp="$2" event="$3" jail="$4" object="$5" description="$6"
    printf '  %s%-19s  %-10s  %-12s  %-39s  %.90s%s\n' \
        "$color" "$timestamp" "$event" "$jail" "$object" "$description" "$C_RESET"
}

format_fail2ban_line() {
    local line="$1" timestamp jail event object description message color
    [[ -n "$line" ]] || return 0
    timestamp="$(fail2ban_extract_timestamp "$line")"

    if [[ "$line" =~ \[([^][]+)\][[:space:]]+(Restore[[:space:]]+Ban|Ban|Unban|Found)[[:space:]]+([0-9a-fA-F:.]+) ]]; then
        jail="${BASH_REMATCH[1]}"
        event="${BASH_REMATCH[2]}"
        object="${BASH_REMATCH[3]}"
        case "$event" in
            Ban)
                fail2ban_print_row "${C_BOLD}${C_RED}" "$timestamp" "封禁" "$jail" "$object" "已加入防火墙黑名单"
                ;;
            "Restore Ban")
                fail2ban_print_row "${C_BOLD}${C_RED}" "$timestamp" "恢复封禁" "$jail" "$object" "服务重启后恢复已有封禁"
                ;;
            Unban)
                fail2ban_print_row "$C_GREEN" "$timestamp" "解封" "$jail" "$object" "封禁时间结束或规则被清理"
                ;;
            Found)
                fail2ban_print_row "$C_YELLOW" "$timestamp" "失败尝试" "$jail" "$object" "检测到一次认证失败"
                ;;
        esac
        return 0
    fi

    message="$(fail2ban_extract_message "$line")"
    jail="-"
    object="-"
    description="$message"
    color="$C_DIM"
    event="信息"

    if [[ "$message" =~ Jail[[:space:]]+\'([^\']+)\'[[:space:]]+(started|stopped) ]]; then
        jail="${BASH_REMATCH[1]}"
        if [[ "${BASH_REMATCH[2]}" == "started" ]]; then
            event="Jail 启动"; color="$C_GREEN"; description="防护规则已开始运行"
        else
            event="Jail 停止"; color="$C_YELLOW"; description="防护规则已停止运行"
        fi
    elif [[ "$message" == *"Starting Fail2ban"* ]]; then
        event="服务启动"; color="${C_BOLD}${C_GREEN}"; object="Fail2ban"; description="Fail2ban 服务正在启动"
    elif [[ "$message" == *"Shutdown in progress"* || "$message" == *"Stopping all jails"* || "$message" == *"Exiting Fail2ban"* ]]; then
        event="服务停止"; color="${C_BOLD}${C_YELLOW}"; object="Fail2ban"; description="$message"
    elif [[ "$message" == *"Flush ticket"* ]]; then
        event="清空规则"; color="${C_BOLD}${C_YELLOW}"; description="停止或重启期间清理防火墙封禁规则"
    elif [[ "$message" =~ (ERROR|CRITICAL|Failed|failed|failure|Exception|Traceback) ]]; then
        event="异常"; color="${C_BOLD}${C_RED}"; description="$message"
    elif [[ "$message" =~ (maxRetry|findtime|banTime|encoding|backend|journal[[:space:]]match) ]]; then
        event="配置"; color="$C_BLUE"; description="$message"
    elif [[ "$message" == *"database"* || "$message" == *"Observer"* ]]; then
        event="内部状态"; color="$C_DIM"; description="$message"
    fi

    fail2ban_print_row "$color" "$timestamp" "$event" "$jail" "$object" "$description"
}

format_fail2ban_stream() {
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        format_fail2ban_line "$line"
    done
}

fail2ban_log_summary() {
    local raw="$1" found bans restored unbans errors
    found="$(grep -cE '\[[^]]+\][[:space:]]+Found[[:space:]]+' <<< "$raw" || true)"
    bans="$(grep -cE '\[[^]]+\][[:space:]]+Ban[[:space:]]+' <<< "$raw" || true)"
    restored="$(grep -cE '\[[^]]+\][[:space:]]+Restore[[:space:]]+Ban[[:space:]]+' <<< "$raw" || true)"
    unbans="$(grep -cE '\[[^]]+\][[:space:]]+Unban[[:space:]]+' <<< "$raw" || true)"
    errors="$(grep -cEi 'ERROR|CRITICAL|Failed|failure|Exception|Traceback' <<< "$raw" || true)"

    printf '\n  %s摘要%s  失败尝试 %s%s%s  封禁 %s%s%s  恢复封禁 %s%s%s  解封 %s%s%s  异常 %s%s%s\n' \
        "$C_BOLD" "$C_RESET" \
        "$C_YELLOW" "$found" "$C_RESET" \
        "${C_BOLD}${C_RED}" "$bans" "$C_RESET" \
        "${C_BOLD}${C_RED}" "$restored" "$C_RESET" \
        "$C_GREEN" "$unbans" "$C_RESET" \
        "${C_BOLD}${C_RED}" "$errors" "$C_RESET"
}

render_fail2ban_logs() {
    local raw="$1"
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        log_warn "没有符合条件的 Fail2ban 日志"
        return 0
    fi
    fail2ban_log_header
    format_fail2ban_stream <<< "$raw"
    fail2ban_log_summary "$raw"
}

read_recent_fail2ban_logs() {
    local lines="$1"
    case "$FAIL2BAN_LOG_SOURCE" in
        file) tail -n "$lines" "$FAIL2BAN_LOG_FILE" ;;
        journal) journalctl -u fail2ban --no-pager -n "$lines" -o short-iso ;;
    esac
}

show_recent_fail2ban_logs() {
    local lines="${1:-$FAIL2BAN_DEFAULT_LINES}" raw
    validate_positive_integer "$lines" || { log_warn "日志条数必须是正整数"; return 1; }
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    ui_title "最近 ${lines} 条 Fail2ban 日志"
    raw="$(read_recent_fail2ban_logs "$lines")"
    render_fail2ban_logs "$raw"
}

follow_fail2ban_logs() {
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    log_info "正在实时跟踪格式化日志，按 Ctrl+C 停止"
    fail2ban_log_header
    case "$FAIL2BAN_LOG_SOURCE" in
        file) tail -n 30 -F "$FAIL2BAN_LOG_FILE" | format_fail2ban_stream ;;
        journal) journalctl -u fail2ban -n 30 -f -o short-iso | format_fail2ban_stream ;;
    esac
}

filter_fail2ban_logs() {
    local event="$1" limit="${2:-500}" raw
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    raw="$(read_recent_fail2ban_logs "$limit")"
    case "$event" in
        Ban) raw="$(grep -E '\[[^]]+\][[:space:]]+(Restore[[:space:]]+Ban|Ban)[[:space:]]+' <<< "$raw" || true)" ;;
        Unban) raw="$(grep -E '\[[^]]+\][[:space:]]+Unban[[:space:]]+' <<< "$raw" || true)" ;;
        Found) raw="$(grep -E '\[[^]]+\][[:space:]]+Found[[:space:]]+' <<< "$raw" || true)" ;;
    esac
    render_fail2ban_logs "$raw"
}

search_fail2ban_ip() {
    local ip="$1" raw
    validate_ip "$ip" || { log_warn "IP 地址格式无效"; return 1; }
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    ui_title "IP ${ip} 的 Fail2ban 记录"
    case "$FAIL2BAN_LOG_SOURCE" in
        file)
            raw="$({ zgrep -h -F -- "$ip" "${FAIL2BAN_LOG_FILE}".*.gz 2>/dev/null || true; grep -F -- "$ip" "$FAIL2BAN_LOG_FILE" || true; })"
            ;;
        journal) raw="$(journalctl -u fail2ban --no-pager -o short-iso | grep -F -- "$ip" || true)" ;;
    esac
    render_fail2ban_logs "$raw"
}

show_logs_since() {
    local since="$1" cutoff raw
    ui_title "Fail2ban 日志：${since} 至今"
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    case "$FAIL2BAN_LOG_SOURCE" in
        journal)
            raw="$(journalctl -u fail2ban --since "$since" --no-pager -o short-iso)"
            ;;
        file)
            cutoff="$(date -d "$since" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" \
                || { log_warn "无法解析时间范围：${since}"; return 1; }
            raw="$({ [[ -r "${FAIL2BAN_LOG_FILE}.1" ]] && cat "${FAIL2BAN_LOG_FILE}.1"; cat "$FAIL2BAN_LOG_FILE"; } \
                | awk -v cutoff="$cutoff" 'length($1) >= 10 && ($1 " " $2) >= cutoff')"
            ;;
    esac
    render_fail2ban_logs "$raw"
}

list_jails() {
    fail2ban-client status 2>/dev/null | awk -F':[[:space:]]*' '/Jail list/ {gsub(/,/, "", $2); print $2}'
}

show_banned_ips() {
    require_fail2ban || return 1
    local jails jail found=0
    jails="$(list_jails)"
    [[ -n "$jails" ]] || { log_warn "当前没有活动 jail"; return 0; }
    ui_title "当前封禁 IP"
    for jail in $jails; do
        printf '%s[%s]%s\n' "$C_BOLD" "$jail" "$C_RESET"
        local line
        line="$(fail2ban-client status "$jail" 2>/dev/null | awk -F':[[:space:]]*' '/Banned IP list/ {print $2}')"
        if [[ -n "$line" ]]; then
            for ip in $line; do printf '  %s%s● %s%s\n' "$C_BOLD" "$C_RED" "$ip" "$C_RESET"; done
            found=1
        else
            printf '  %s暂无封禁%s\n' "$C_DIM" "$C_RESET"
        fi
        printf '\n'
    done
    (( found == 1 )) || log_success "当前没有被封禁的 IP"
}

unban_ip_interactive() {
    require_fail2ban || return 1
    local jail ip jails
    jails="$(list_jails)"
    [[ -n "$jails" ]] || { log_warn "当前没有活动 jail"; return 1; }
    printf '  可用 jail：%s\n' "$jails"
    jail="$(prompt_value 'Jail 名称' "$FAIL2BAN_DEFAULT_JAIL")"
    grep -qw -- "$jail" <<< "$jails" || { log_warn "Jail 不存在：${jail}"; return 1; }
    ip="$(prompt_value '要解封的 IP 地址' '')"
    validate_ip "$ip" || { log_warn "IP 地址格式无效"; return 1; }
    confirm "确认从 ${jail} 解封 ${ip}" "Y" || return 0
    if fail2ban-client set "$jail" unbanip "$ip" >/dev/null; then
        log_success "已从 ${jail} 解封 ${ip}"
    else
        log_error "解封失败；该 IP 可能未被 ${jail} 封禁"
        return 1
    fi
}

fail2ban_log_menu() {
    local choice lines ip
    while true; do
        ui_header
        ui_title "Fail2ban 日志中心"
        ui_menu_item 1 "最近日志" "格式化显示，默认 ${FAIL2BAN_DEFAULT_LINES} 条"
        ui_menu_item 2 "实时跟踪" "格式化显示，Ctrl+C 停止"
        ui_menu_item 3 "封禁记录" "红色重点标记"
        ui_menu_item 4 "解封记录" "绿色标记"
        ui_menu_item 5 "查询指定 IP"
        ui_menu_item 6 "最近 1 小时"
        ui_menu_item 7 "最近 24 小时"
        ui_menu_item 8 "当前封禁 IP"
        ui_menu_item 9 "解封 IP"
        ui_menu_item 0 "返回主菜单"
        printf '\n'
        choice="$(select_number '请选择' 0 9 1)" || return
        case "$choice" in
            1)
                lines="$(prompt_value '查看条数' "$FAIL2BAN_DEFAULT_LINES")"
                show_recent_fail2ban_logs "$lines"; pause_screen
                ;;
            2)
                trap 'printf "\n"' INT
                follow_fail2ban_logs || true
                trap - INT
                pause_screen
                ;;
            3) ui_header; ui_title "最近封禁记录"; filter_fail2ban_logs 'Ban'; pause_screen ;;
            4) ui_header; ui_title "最近解封记录"; filter_fail2ban_logs 'Unban'; pause_screen ;;
            5)
                ip="$(prompt_value 'IP 地址' '')"
                ui_header; search_fail2ban_ip "$ip"; pause_screen
                ;;
            6) ui_header; show_logs_since '1 hour ago'; pause_screen ;;
            7) ui_header; show_logs_since '24 hours ago'; pause_screen ;;
            8) ui_header; show_banned_ips; pause_screen ;;
            9) ui_header; ui_title "解封 IP"; unban_ip_interactive; pause_screen ;;
            0) return ;;
        esac
    done
}
