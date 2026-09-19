#!/usr/bin/env bash

show_full_status() {
    ui_header
    ui_title "系统状态总览"
    show_preflight
    ui_title "SSH"
    show_ssh_status
    printf '\n'
    ui_title "Fail2ban"
    if command_exists fail2ban-client; then
        printf '  %-22s %s\n' '服务状态' "$(systemctl is-active fail2ban 2>/dev/null || true)"
        printf '  %-22s %s\n' '开机启动' "$(systemctl is-enabled fail2ban 2>/dev/null || true)"
        printf '  %-22s %s\n' '版本' "$(fail2ban-client version 2>/dev/null || true)"
        fail2ban-client status 2>/dev/null || true
    else
        log_warn "Fail2ban：未安装"
    fi
    printf '\n'
    show_bbr_status
    printf '\n'
    printf '  %-22s %s\n' '安装日志' "$APP_LOG_FILE"
    printf '  %-22s %s\n' '备份目录' "$APP_BACKUP_DIR"
}
