#!/usr/bin/env bash

FAIL2BAN_JAIL_FILE="/etc/fail2ban/jail.d/99-vps-tool.local"
FAIL2BAN_LOG_CONFIG="/etc/fail2ban/fail2ban.d/99-vps-tool.local"

install_fail2ban_packages() {
    log_info "正在更新软件包索引..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y >> "$APP_LOG_FILE" 2>&1 \
        || { log_error "apt-get update 失败，详情见 ${APP_LOG_FILE}"; return 1; }
    log_info "正在安装 Fail2ban、日志轮转和 systemd 后端依赖..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd logrotate curl ca-certificates >> "$APP_LOG_FILE" 2>&1 \
        || { log_error "Fail2ban 安装失败，详情见 ${APP_LOG_FILE}"; return 1; }
    log_success "Fail2ban 已安装"
}

write_fail2ban_config() {
    local ssh_port="$1" maxretry="$2" findtime="$3" bantime="$4" max_bantime="$5"
    mkdir -p /etc/fail2ban/jail.d /etc/fail2ban/fail2ban.d

    cat > "$FAIL2BAN_JAIL_FILE" <<EOF_JAIL
# Managed by vps-tool. Generated: $(date -Is)
[DEFAULT]
bantime = ${bantime}
findtime = ${findtime}
maxretry = ${maxretry}
bantime.increment = true
bantime.factor = 2
bantime.maxtime = ${max_bantime}

[sshd]
enabled = true
port = ${ssh_port}
backend = systemd
mode = normal
EOF_JAIL

    cat > "$FAIL2BAN_LOG_CONFIG" <<EOF_LOG
# Managed by vps-tool
[Definition]
loglevel = INFO
logtarget = ${FAIL2BAN_LOG_FILE}
syslogsocket = auto
EOF_LOG
    chmod 644 "$FAIL2BAN_JAIL_FILE" "$FAIL2BAN_LOG_CONFIG"
}

configure_fail2ban_interactive() {
    ui_header
    ui_title "Fail2ban 安装与防护"
    check_supported_os

    local ssh_port maxretry findtime bantime max_bantime retention
    detect_current_ssh_port
    ui_section "01" "防护参数"
    ssh_port="$(prompt_value '需要保护的 SSH 端口' "$CURRENT_SSH_PORT")"
    validate_port "$ssh_port" || { log_error "SSH 端口无效"; return 1; }

    while true; do
        maxretry="$(prompt_value '允许的最大失败次数' "$FAIL2BAN_MAXRETRY")"
        validate_positive_integer "$maxretry" && break
        log_warn "请输入正整数"
    done
    findtime="$(prompt_value '检测时间窗口' "$FAIL2BAN_FINDTIME")"
    bantime="$(prompt_value '首次封禁时间' "$FAIL2BAN_BANTIME")"
    max_bantime="$(prompt_value '递增封禁的最长时间' "$FAIL2BAN_MAX_BANTIME")"
    while true; do
        retention="$(prompt_value 'Fail2ban 日志保留天数' "$FAIL2BAN_LOG_RETENTION_DAYS")"
        validate_positive_integer "$retention" && break
        log_warn "请输入正整数"
    done

    ui_section "02" "配置预览"
    ui_kv "SSH 端口" "$ssh_port"
    ui_kv "最大失败次数" "$maxretry"
    ui_kv "检测时间窗口" "$findtime"
    ui_kv "首次封禁" "$bantime"
    ui_kv "最长封禁" "$max_bantime"
    ui_kv "日志保留" "${retention} 天"
    printf '\n'
    confirm "确认安装并启用 Fail2ban" "Y" || { log_warn "已取消"; return 0; }

    install_fail2ban_packages || return 1
    write_fail2ban_config "$ssh_port" "$maxretry" "$findtime" "$bantime" "$max_bantime"
    configure_logrotate "$retention" || return 1

    if ! fail2ban-client -t >> "$APP_LOG_FILE" 2>&1; then
        log_error "Fail2ban 配置验证失败，详情见 ${APP_LOG_FILE}"
        return 1
    fi
    systemctl enable --now fail2ban >> "$APP_LOG_FILE" 2>&1
    systemctl restart fail2ban >> "$APP_LOG_FILE" 2>&1
    sleep 2
    service_active fail2ban || { log_error "Fail2ban 启动失败"; journalctl -u fail2ban -n 20 --no-pager; return 1; }
    fail2ban-client status sshd >/dev/null 2>&1 || { log_error "sshd jail 未成功启用"; return 1; }

    cat > "${APP_STATE_DIR}/fail2ban.conf" <<EOF_STATE
SSH_PORT=$(printf '%q' "$ssh_port")
MAXRETRY=$(printf '%q' "$maxretry")
FINDTIME=$(printf '%q' "$findtime")
BANTIME=$(printf '%q' "$bantime")
LOG_RETENTION_DAYS=$(printf '%q' "$retention")
UPDATED_AT=$(printf '%q' "$(date -Is)")
EOF_STATE
    chmod 600 "${APP_STATE_DIR}/fail2ban.conf"
    log_success "Fail2ban 已启用，sshd jail 正常运行"
}

print_fail2ban_status() {
    if ! command_exists fail2ban-client; then
        ui_kv "安装状态" "${C_YELLOW}▲ 未安装${C_RESET}"
        return 1
    fi

    local service_state enabled_state version status jail_list jail_count
    local current_failed total_failed current_banned total_banned banned_ips
    service_state="$(systemctl is-active fail2ban 2>/dev/null || true)"
    enabled_state="$(systemctl is-enabled fail2ban 2>/dev/null || true)"
    version="$(fail2ban-client version 2>/dev/null || printf 'unknown')"
    status="$(fail2ban-client status 2>/dev/null || true)"
    jail_list="$(awk -F':[[:space:]]*' '/Jail list/ {print $2}' <<< "$status")"
    jail_count="$(awk -F':[[:space:]]*' '/Number of jail/ {print $2}' <<< "$status")"

    ui_kv "服务状态" "$(ui_state "$service_state")"
    ui_kv "开机启动" "$(ui_state "$enabled_state")"
    ui_kv "版本" "$version"
    ui_kv "活动 Jail" "${jail_count:-0}  ${C_DIM}${jail_list:-无}${C_RESET}"

    if fail2ban-client status sshd >/dev/null 2>&1; then
        status="$(fail2ban-client status sshd 2>/dev/null)"
        current_failed="$(awk -F':[[:space:]]*' '/Currently failed/ {print $2}' <<< "$status")"
        total_failed="$(awk -F':[[:space:]]*' '/Total failed/ {print $2}' <<< "$status")"
        current_banned="$(awk -F':[[:space:]]*' '/Currently banned/ {print $2}' <<< "$status")"
        total_banned="$(awk -F':[[:space:]]*' '/Total banned/ {print $2}' <<< "$status")"
        banned_ips="$(awk -F':[[:space:]]*' '/Banned IP list/ {print $2}' <<< "$status")"
        ui_subtitle "sshd 防护统计"
        ui_kv "当前失败" "${C_YELLOW}${current_failed:-0}${C_RESET}"
        ui_kv "累计失败" "${total_failed:-0}"
        ui_kv "当前封禁" "${C_BOLD}${C_RED}${current_banned:-0}${C_RESET}"
        ui_kv "累计封禁" "${C_RED}${total_banned:-0}${C_RESET}"
        if [[ -n "$banned_ips" ]]; then
            ui_kv "封禁 IP" "${C_BOLD}${C_RED}${banned_ips}${C_RESET}"
        else
            ui_kv "封禁 IP" "${C_DIM}暂无${C_RESET}"
        fi
    fi
}

show_fail2ban_status() {
    ui_header
    ui_title "Fail2ban 状态"
    ui_section "01" "服务概览"
    print_fail2ban_status
}
