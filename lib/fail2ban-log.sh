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

show_recent_fail2ban_logs() {
    local lines="${1:-$FAIL2BAN_DEFAULT_LINES}"
    validate_positive_integer "$lines" || { log_warn "日志条数必须是正整数"; return 1; }
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    ui_title "最近 ${lines} 条 Fail2ban 日志"
    case "$FAIL2BAN_LOG_SOURCE" in
        file) tail -n "$lines" "$FAIL2BAN_LOG_FILE" ;;
        journal) journalctl -u fail2ban --no-pager -n "$lines" ;;
    esac
}

follow_fail2ban_logs() {
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    log_info "正在实时跟踪日志，按 Ctrl+C 停止"
    case "$FAIL2BAN_LOG_SOURCE" in
        file) tail -n 30 -F "$FAIL2BAN_LOG_FILE" ;;
        journal) journalctl -u fail2ban -n 30 -f ;;
    esac
}

filter_fail2ban_logs() {
    local event="$1" limit="${2:-500}"
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    case "$FAIL2BAN_LOG_SOURCE" in
        file) tail -n "$limit" "$FAIL2BAN_LOG_FILE" | grep -E "\] ${event} " || true ;;
        journal) journalctl -u fail2ban --no-pager -n "$limit" | grep -E "\] ${event} " || true ;;
    esac
}

search_fail2ban_ip() {
    local ip="$1"
    validate_ip "$ip" || { log_warn "IP 地址格式无效"; return 1; }
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    ui_title "IP ${ip} 的 Fail2ban 记录"
    case "$FAIL2BAN_LOG_SOURCE" in
        file)
            { zgrep -h -F -- "$ip" "${FAIL2BAN_LOG_FILE}".*.gz 2>/dev/null || true; grep -F -- "$ip" "$FAIL2BAN_LOG_FILE" || true; }
            ;;
        journal) journalctl -u fail2ban --no-pager | grep -F -- "$ip" || true ;;
    esac
}

show_logs_since() {
    local since="$1" cutoff
    ui_title "Fail2ban 日志：${since} 至今"
    detect_fail2ban_log_source || { log_warn "找不到 Fail2ban 日志"; return 1; }
    case "$FAIL2BAN_LOG_SOURCE" in
        journal)
            journalctl -u fail2ban --since "$since" --no-pager
            ;;
        file)
            cutoff="$(date -d "$since" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"                 || { log_warn "无法解析时间范围：${since}"; return 1; }
            {
                [[ -r "${FAIL2BAN_LOG_FILE}.1" ]] && cat "${FAIL2BAN_LOG_FILE}.1"
                cat "$FAIL2BAN_LOG_FILE"
            } | awk -v cutoff="$cutoff" 'length($1) >= 10 && ($1 " " $2) >= cutoff'
            ;;
    esac
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
            for ip in $line; do printf '  %s●%s %s\n' "$C_RED" "$C_RESET" "$ip"; done
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
    confirm "确认从 ${jail} 解封 ${ip}" "N" || return 0
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
        ui_menu_item 1 "最近日志" "默认 ${FAIL2BAN_DEFAULT_LINES} 条"
        ui_menu_item 2 "实时跟踪" "Ctrl+C 停止"
        ui_menu_item 3 "封禁记录" "Ban"
        ui_menu_item 4 "解封记录" "Unban"
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
