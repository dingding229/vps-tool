#!/usr/bin/env bash

show_full_status() {
    ui_header
    ui_title "系统状态总览"

    show_preflight "01"

    ui_section "02" "SSH 安全"
    show_ssh_status

    ui_section "03" "Fail2ban 防护"
    print_fail2ban_status || true

    ui_section "04" "网络加速"
    show_bbr_status

    ui_section "05" "文件与备份"
    ui_kv "安装日志" "$APP_LOG_FILE"
    ui_kv "备份目录" "$APP_BACKUP_DIR"
    ui_kv "配置目录" "$APP_ETC_DIR"
    ui_kv "状态目录" "$APP_STATE_DIR"
}
