#!/usr/bin/env bash

configure_logrotate() {
    local retention="${1:-$FAIL2BAN_LOG_RETENTION_DAYS}"
    validate_positive_integer "$retention" || { log_error "日志保留天数无效：${retention}"; return 1; }

    cat > /etc/logrotate.d/vps-tool-fail2ban <<EOF_ROTATE
${FAIL2BAN_LOG_FILE} {
    daily
    rotate ${retention}
    maxage ${retention}
    missingok
    compress
    delaycompress
    notifempty
    create 0640 root adm
    sharedscripts
    postrotate
        /usr/bin/fail2ban-client flushlogs >/dev/null 2>&1 || true
    endscript
}
EOF_ROTATE

    cat > /etc/logrotate.d/vps-tool <<'EOF_ROTATE'
/var/log/vps-tool/*.log {
    weekly
    rotate 4
    maxage 30
    missingok
    compress
    delaycompress
    notifempty
    create 0600 root root
}
EOF_ROTATE

    chmod 644 /etc/logrotate.d/vps-tool-fail2ban /etc/logrotate.d/vps-tool
    if command_exists logrotate; then
        logrotate --debug /etc/logrotate.d/vps-tool-fail2ban >/dev/null 2>&1 \
            || { log_error "Fail2ban logrotate 配置验证失败"; return 1; }
        logrotate --debug /etc/logrotate.d/vps-tool >/dev/null 2>&1 \
            || { log_error "vps-tool logrotate 配置验证失败"; return 1; }
    fi
    log_success "日志自动轮转已配置，Fail2ban 日志保留 ${retention} 天"
}
