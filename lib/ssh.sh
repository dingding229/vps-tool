#!/usr/bin/env bash

SSH_SERVICE="ssh"
CURRENT_SSH_PORT=22
NEW_SSH_PORT=""

ssh_service_name() {
    if systemctl cat ssh.service >/dev/null 2>&1; then
        SSH_SERVICE="ssh"
    elif systemctl cat sshd.service >/dev/null 2>&1; then
        SSH_SERVICE="sshd"
    else
        die "未找到 ssh.service 或 sshd.service"
    fi
}

detect_current_ssh_port() {
    local detected
    detected="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
    CURRENT_SSH_PORT="${detected:-22}"
}

random_ssh_port() {
    local port attempts=0
    while (( attempts < 50 )); do
        port=$(( SSH_PORT_MIN + RANDOM % (SSH_PORT_MAX - SSH_PORT_MIN + 1) ))
        if ! ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${port}$"; then
            printf '%s' "$port"
            return 0
        fi
        ((attempts++))
    done
    printf '35222'
}

write_ssh_dropin() {
    local port="$1" allow_root="$2"
    mkdir -p "$(dirname "$SSH_DROPIN_FILE")"
    cat > "$SSH_DROPIN_FILE" <<EOF_SSH
# Managed by vps-tool. Generated: $(date -Is)
Port ${port}
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitEmptyPasswords no
AuthenticationMethods publickey
PermitRootLogin ${allow_root}
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
EOF_SSH
    chmod 600 "$SSH_DROPIN_FILE"
}

verify_effective_ssh_config() {
    local port="$1" target_user="$2" effective
    sshd -t || return 1
    effective="$(sshd -T -C "user=${target_user},host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 1
    local effective_ports
    effective_ports="$(awk '$1=="port" {print $2}' <<< "$effective")"
    [[ "$effective_ports" == "$port" ]] || { log_error "有效 SSH 端口不是唯一的 ${port}（当前：${effective_ports//$'\n'/,}）"; return 1; }
    grep -qx 'passwordauthentication no' <<< "$effective" || { log_error "PasswordAuthentication 未生效"; return 1; }
    grep -qx 'kbdinteractiveauthentication no' <<< "$effective" || { log_error "KbdInteractiveAuthentication 未生效"; return 1; }
    grep -qx 'pubkeyauthentication yes' <<< "$effective" || { log_error "PubkeyAuthentication 未生效"; return 1; }
}

configure_ssh_interactive() {
    ui_header
    ui_title "SSH 安全配置"
    local required_cmd
    for required_cmd in sshd ss systemctl systemd-run flock ssh-keygen; do
        command_exists "$required_cmd" || { log_error "缺少必要命令：${required_cmd}"; return 1; }
    done
    ssh_service_name
    detect_current_ssh_port
    printf '  当前 SSH 端口：%s%s%s\n' "$C_BOLD" "$CURRENT_SSH_PORT" "$C_RESET"

    local target_user default_port new_port root_policy backup_dir backup_file existed=0
    target_user="$(prompt_value '配置密钥登录的用户' "${SUDO_USER:-root}")"
    ensure_authorized_key "$target_user"

    default_port="$(random_ssh_port)"
    while true; do
        new_port="$(prompt_value '新的 SSH 端口' "$default_port")"
        validate_port "$new_port" || { log_warn "端口必须为 1-65535"; continue; }
        if [[ "$new_port" != "$CURRENT_SSH_PORT" ]] && ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${new_port}$"; then
            log_warn "端口 ${new_port} 已被占用"
            continue
        fi
        break
    done
    NEW_SSH_PORT="$new_port"

    root_policy="prohibit-password"
    if [[ "$target_user" != "root" ]] && confirm "完全禁止 root SSH 登录" "N"; then
        if ! id -nG "$target_user" | tr ' ' '
' | grep -qx 'sudo'; then
            log_error "用户 ${target_user} 不在 sudo 组中，拒绝禁用 root SSH 登录"
            return 1
        fi
        command_exists sudo || { log_error "系统未安装 sudo，拒绝禁用 root SSH 登录"; return 1; }
        root_policy="no"
    fi

    printf '\n%s即将应用：%s\n' "$C_BOLD" "$C_RESET"
    printf '  • SSH 端口：%s → %s\n' "$CURRENT_SSH_PORT" "$NEW_SSH_PORT"
    printf '  • 登录方式：仅公钥\n'
    printf '  • root 策略：%s\n' "$root_policy"
    printf '  • 自动回滚：%s 秒\n\n' "$SSH_ROLLBACK_TIMEOUT"
    confirm "确认继续" "N" || { log_warn "已取消 SSH 配置"; return 0; }

    firewall_allow_ssh_port "$NEW_SSH_PORT" || { log_error "未确认新端口已放行，已停止"; return 1; }

    backup_dir="$(create_backup_dir)"
    backup_file="${backup_dir}/00-vps-tool.conf"
    if [[ -f "$SSH_DROPIN_FILE" ]]; then
        cp -a "$SSH_DROPIN_FILE" "$backup_file"
        existed=1
    fi

    write_ssh_dropin "$NEW_SSH_PORT" "$root_policy"
    if ! verify_effective_ssh_config "$NEW_SSH_PORT" "$target_user"; then
        log_error "SSH 配置验证失败，正在恢复"
        [[ "$existed" == "1" ]] && cp -a "$backup_file" "$SSH_DROPIN_FILE" || rm -f "$SSH_DROPIN_FILE"
        firewall_remove_ssh_port "$NEW_SSH_PORT"
        return 1
    fi
    log_success "sshd 配置语法和有效参数验证通过"

    if ! schedule_ssh_rollback "$backup_file" "$existed" "$NEW_SSH_PORT" "$FIREWALL_KIND" "$SSH_SERVICE" "$SSH_ROLLBACK_TIMEOUT"; then
        log_error "无法创建 SSH 自动回滚任务，已恢复原配置"
        [[ "$existed" == "1" ]] && cp -a "$backup_file" "$SSH_DROPIN_FILE" || rm -f "$SSH_DROPIN_FILE"
        firewall_remove_ssh_port "$NEW_SSH_PORT"
        return 1
    fi
    systemctl reload "$SSH_SERVICE"
    sleep 1
    ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${NEW_SSH_PORT}$" \
        || { log_error "未检测到 SSH 监听新端口，立即回滚"; run_ssh_rollback_now; return 1; }

    printf '\n%s%s╭──────────────────── 重要：连接验证 ────────────────────╮%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%s│%s 请勿关闭当前窗口。请新开终端执行：                     %s│%s\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf '%s│%s %sssh -p %s %s@服务器IP%s%*s%s│%s\n' "$C_YELLOW" "$C_RESET" "$C_BOLD" "$NEW_SSH_PORT" "$target_user" "$C_RESET" 16 '' "$C_YELLOW" "$C_RESET"
    printf '%s│%s 新连接成功后，在下方输入大写 CONFIRM。                 %s│%s\n' "$C_YELLOW" "$C_RESET" "$C_YELLOW" "$C_RESET"
    printf '%s╰──────────────────────────────────────────────────────────╯%s\n' "$C_YELLOW" "$C_RESET"

    local answer
    while true; do
        answer="$(prompt_value '请输入 CONFIRM，或输入 ROLLBACK 立即恢复' '')"
        case "$answer" in
            CONFIRM)
                if ! cancel_ssh_rollback "$NEW_SSH_PORT"; then
                    log_error "自动回滚可能已经执行；不会删除旧端口规则。请重新运行 SSH 配置"
                    return 1
                fi
                if [[ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]]; then
                    firewall_remove_ssh_port "$CURRENT_SSH_PORT"
                fi
                printf 'SSH_PORT=%q\nSSH_USER=%q\nUPDATED_AT=%q\n' \
                    "$NEW_SSH_PORT" "$target_user" "$(date -Is)" > "${APP_STATE_DIR}/ssh.conf"
                chmod 600 "${APP_STATE_DIR}/ssh.conf"
                log_success "SSH 安全配置已完成"
                return 0
                ;;
            ROLLBACK)
                run_ssh_rollback_now
                log_warn "SSH 配置已回滚"
                return 1
                ;;
            *) log_warn "请先在第二个终端验证连接，然后输入 CONFIRM" ;;
        esac
    done
}

show_ssh_status() {
    ssh_service_name
    detect_current_ssh_port
    printf '  %-22s %s\n' 'SSH 服务' "$(systemctl is-active "$SSH_SERVICE" 2>/dev/null || true)"
    printf '  %-22s %s\n' '有效端口' "$CURRENT_SSH_PORT"
    local cfg
    cfg="$(sshd -T 2>/dev/null || true)"
    printf '  %-22s %s\n' '公钥认证' "$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$cfg")"
    printf '  %-22s %s\n' '密码认证' "$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$cfg")"
    printf '  %-22s %s\n' '交互式认证' "$(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$cfg")"
}
