#!/usr/bin/env bash

run_all() {
    run_preflight || return 1
    configure_ssh_interactive || return 1
    configure_fail2ban_interactive || return 1
    configure_vnstat_interactive || return 1
    install_bbr_interactive || return 1
    if [[ "$BBR_REBOOT_SCHEDULED" == "yes" || "$BBR_REBOOT_REQUIRED" == "yes" ]]; then
        return 0
    fi
    verify_system
}

main_menu() {
    local choice
    while true; do
        ui_header
        ui_title "主菜单"

        ui_menu_group "快速开始"
        ui_menu_item 1 "一键完成全部配置" "SSH + Fail2ban + vnStat + BBRv3"

        ui_menu_group "SSH 与登录"
        ui_menu_item 2 "配置 SSH 安全策略" "密钥登录 / 修改端口"
        ui_menu_item 3 "启用 root SSH 登录" "默认仅密钥 / 可选密码"
        ui_menu_item 4 "执行 SSH 配置回滚" "恢复待确认的 SSH 配置"

        ui_menu_group "访问防护"
        ui_menu_item 5 "安装和配置 Fail2ban" "防止 SSH 暴力破解"
        ui_menu_item 6 "查看 Fail2ban 日志" "安全事件 / 封禁管理"

        ui_menu_group "网络与流量"
        ui_menu_item 7 "vnStat 流量中心" "安装配置 / 流量查询"
        ui_menu_item 8 "安装 BBRv3" "安全重启 / 开机自动恢复"

        ui_menu_group "系统维护"
        ui_menu_item 9 "查看系统状态" "服务与配置总览"
        ui_menu_item 10 "检查系统配置" "SSH / 防护 / 流量 / 内核"
        ui_menu_item 11 "APT 软件包更新" "刷新索引 / 检查并升级"
        ui_menu_item 12 "检查 VPS Tool 更新" "自动更新 / 手动检查"

        ui_menu_group "其他"
        ui_menu_item 0 "退出"
        printf '\n'
        choice="$(select_number '请选择功能' 0 12 1)" || return
        case "$choice" in
            1)
                run_all
                [[ "$BBR_REBOOT_SCHEDULED" == "yes" ]] && return 0
                pause_screen
                ;;
            2) configure_ssh_interactive; pause_screen ;;
            3) enable_root_login_interactive; pause_screen ;;
            4) run_ssh_rollback_now; pause_screen ;;
            5) configure_fail2ban_interactive; pause_screen ;;
            6) fail2ban_log_menu ;;
            7) vnstat_menu ;;
            8)
                install_bbr_interactive
                [[ "$BBR_REBOOT_SCHEDULED" == "yes" ]] && return 0
                pause_screen
                ;;
            9) show_full_status; pause_screen ;;
            10) verify_system; pause_screen ;;
            11) manage_apt_interactive; pause_screen ;;
            12) update_now_interactive; pause_screen ;;
            0) printf '\n%s再见。%s\n' "$C_CYAN" "$C_RESET"; return 0 ;;
        esac
    done
}
