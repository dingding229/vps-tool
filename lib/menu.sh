#!/usr/bin/env bash

run_all() {
    run_preflight || return 1
    configure_ssh_interactive || return 1
    configure_fail2ban_interactive || return 1
    install_bbr_interactive || return 1
    verify_system
}

main_menu() {
    local choice
    while true; do
        ui_header
        ui_title "主菜单"

        ui_menu_group "快速开始"
        ui_menu_item 1 "一键完成全部配置" "SSH + Fail2ban + BBRv3"

        ui_menu_group "安全与网络配置"
        ui_menu_item 2 "配置 SSH 安全策略" "密钥登录 / 修改端口"
        ui_menu_item 3 "启用 root SSH 登录" "默认仅密钥 / 可选密码"
        ui_menu_item 4 "安装和配置 Fail2ban" "防暴力破解"
        ui_menu_item 5 "安装 BBRv3" "自定义内核 / 需要重启"

        ui_menu_group "监控与维护"
        ui_menu_item 6 "查看 Fail2ban 日志" "格式化安全事件"
        ui_menu_item 7 "查看系统状态" "配置状态总览"
        ui_menu_item 8 "验证系统配置" "安全检查"
        ui_menu_item 9 "立即执行 SSH 回滚" "恢复待确认配置"

        ui_menu_group "其他"
        ui_menu_item 0 "退出"
        printf '\n'
        choice="$(select_number '请选择功能' 0 9 1)" || return
        case "$choice" in
            1) run_all; pause_screen ;;
            2) configure_ssh_interactive; pause_screen ;;
            3) enable_root_login_interactive; pause_screen ;;
            4) configure_fail2ban_interactive; pause_screen ;;
            5) install_bbr_interactive; pause_screen ;;
            6) fail2ban_log_menu ;;
            7) show_full_status; pause_screen ;;
            8) verify_system; pause_screen ;;
            9) run_ssh_rollback_now; pause_screen ;;
            0) printf '\n%s再见。%s\n' "$C_CYAN" "$C_RESET"; return 0 ;;
        esac
    done
}
