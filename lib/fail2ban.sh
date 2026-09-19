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

    printf '\n  SSH 端口：%s\n  失败次数：%s\n  检测窗口：%s\n  首次封禁：%s\n  日志保留：%s 天\n\n' \
        "$ssh_port" "$maxretry" "$findtime" "$bantime" "$retention"
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

show_fail2ban_status() {
    ui_header
    ui_title "Fail2ban 状态"
    if ! command_exists fail2ban-client; then
        log_warn "Fail2ban 尚未安装"
        return 1
    fi
    printf '  %-22s %s\n' '服务状态' "$(systemctl is-active fail2ban 2>/dev/null || true)"
    printf '  %-22s %s\n' '开机启动' "$(systemctl is-enabled fail2ban 2>/dev/null || true)"
    printf '  %-22s %s\n' '版本' "$(fail2ban-client version 2>/dev/null || true)"
    printf '\n'
    fail2ban-client status 2>/dev/null || true
    printf '\n'
    if fail2ban-client status sshd >/dev/null 2>&1; then
        fail2ban-client status sshd
    fi
}
