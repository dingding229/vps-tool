#!/usr/bin/env bash

verify_ssh() {
    local cfg port password pubkey interactive service_state
    cfg="$(sshd -T 2>/dev/null || true)"
    port="$(awk '$1=="port" {print $2; exit}' <<< "$cfg")"
    password="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$cfg")"
    pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$cfg")"
    interactive="$(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$cfg")"
    service_state="$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true)"

    ui_kv "SSH 服务" "$(ui_state "$service_state")"
    ui_kv "有效端口" "${C_BOLD}${C_CYAN}${port:-unknown}${C_RESET}"
    ui_kv "公钥认证" "$(ui_expect "${pubkey:-unknown}" yes)"
    ui_kv "密码认证" "$(ui_expect "${password:-unknown}" no)"
    ui_kv "交互式认证" "$(ui_expect "${interactive:-unknown}" no)"
    if [[ -r "${APP_STATE_DIR}/root-login.conf" ]]; then
        if verify_root_login; then
            ui_kv "root 登录验证" "${C_GREEN}✔ 专用策略正常${C_RESET}"
        else
            ui_kv "root 登录验证" "${C_RED}✖ 专用策略异常${C_RESET}"
            return 1
        fi
    else
        ui_kv "root 登录验证" "${C_DIM}未由工具启用${C_RESET}"
    fi
    [[ "$password" == no && "$pubkey" == yes && "$interactive" == no ]]
}

verify_root_login() {
    local state_file="${APP_STATE_DIR}/root-login.conf" mode
    [[ -r "$state_file" ]] || return 2
    mode="$(awk -F= '$1=="MODE" {gsub(/^'"'"'|'"'"'$/, "", $2); print $2; exit}' "$state_file")"
    [[ "$mode" == "key" || "$mode" == "password" ]] || return 1
    verify_root_access_config "$mode"
}

verify_fail2ban() {
    command_exists fail2ban-client || return 1
    service_active fail2ban || return 1
    fail2ban-client status sshd >/dev/null 2>&1
}

verify_system() {
    ui_header
    ui_title "配置验证"
    local failures=0

    ui_section "01" "SSH 安全检查"
    if verify_ssh; then
        log_success "SSH 核心安全配置通过"
    else
        log_error "SSH 核心安全配置未通过"
        ((failures++))
    fi

    ui_section "02" "Fail2ban 检查"
    if verify_fail2ban; then
        print_fail2ban_status
        log_success "Fail2ban 服务和 sshd Jail 正常"
    else
        print_fail2ban_status || true
        log_warn "Fail2ban 未安装、未运行或 sshd Jail 未启用"
    fi

    ui_section "03" "BBR / 内核检查"
    show_bbr_status

    ui_section "04" "回滚保护"
    if [[ -f "$SSH_ROLLBACK_STATE" ]]; then
        ui_kv "SSH 回滚任务" "${C_YELLOW}▲ 等待确认${C_RESET}"
        log_warn "当前存在待确认的 SSH 自动回滚任务"
    else
        ui_kv "SSH 回滚任务" "${C_GREEN}✔ 无待处理任务${C_RESET}"
    fi

    (( failures == 0 ))
}
