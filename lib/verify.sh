#!/usr/bin/env bash

verify_ssh() {
    local cfg port password pubkey
    cfg="$(sshd -T 2>/dev/null || true)"
    port="$(awk '$1=="port" {print $2; exit}' <<< "$cfg")"
    password="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$cfg")"
    pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$cfg")"
    printf '  %-28s %s\n' 'SSH 服务' "$(systemctl is-active ssh 2>/dev/null || systemctl is-active sshd 2>/dev/null || true)"
    printf '  %-28s %s\n' 'SSH 有效端口' "${port:-unknown}"
    printf '  %-28s %s\n' '公钥认证' "${pubkey:-unknown}"
    printf '  %-28s %s\n' '密码认证' "${password:-unknown}"
    [[ "$password" == no && "$pubkey" == yes ]]
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
    printf '%sSSH%s\n' "$C_BOLD" "$C_RESET"
    if verify_ssh; then log_success "SSH 核心安全配置通过"; else log_error "SSH 核心安全配置未通过"; ((failures++)); fi
    printf '\n%sFail2ban%s\n' "$C_BOLD" "$C_RESET"
    if verify_fail2ban; then
        log_success "Fail2ban 服务和 sshd jail 正常"
        fail2ban-client status sshd 2>/dev/null || true
    else
        log_warn "Fail2ban 未安装、未运行或 sshd jail 未启用"
    fi
    printf '\n%sBBR / 内核%s\n' "$C_BOLD" "$C_RESET"
    show_bbr_status
    printf '\n'
    if [[ -f "$SSH_ROLLBACK_STATE" ]]; then
        log_warn "当前存在待确认的 SSH 自动回滚任务"
    else
        log_success "没有待处理的 SSH 回滚任务"
    fi
    (( failures == 0 ))
}
