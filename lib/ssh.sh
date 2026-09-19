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

effective_ssh_ports() {
    local target_user="${1:-root}"
    sshd -T -C "user=${target_user},host=localhost,addr=127.0.0.1" 2>/dev/null \
        | awk '$1=="port" {print $2}'
}

unique_port_list() {
    awk 'NF && !seen[$1]++ {print $1}'
}

ssh_key_only_login_is_effective() {
    local target_user="$1" effective password pubkey interactive methods permit_root
    effective="$(sshd -T -C "user=${target_user},host=localhost,addr=127.0.0.1" 2>/dev/null)" \
        || return 1
    password="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$effective")"
    pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$effective")"
    interactive="$(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$effective")"
    methods="$(awk '$1=="authenticationmethods" {print $2; exit}' <<< "$effective")"
    [[ "$password" == "no" && "$pubkey" == "yes" \
        && "$interactive" == "no" && "$methods" == "publickey" ]] || return 1

    if [[ "$target_user" == "root" ]]; then
        permit_root="$(awk '$1=="permitrootlogin" {print $2; exit}' <<< "$effective")"
        [[ "$permit_root" == "prohibit-password" ]]
    fi
}

should_write_ssh_port() {
    local new_port="$1" current_port="$2" target_user="${3:-root}"
    local current_ports current_count
    [[ "$new_port" != "$current_port" ]] && return 0

    # 当前端口由 vps-tool 自己管理且没有重复来源时必须保留；否则跳过重复 Port 声明。
    if [[ -f "$SSH_DROPIN_FILE" ]] \
        && awk -v wanted="$current_port" 'tolower($1)=="port" && $2==wanted {found=1} END {exit !found}' "$SSH_DROPIN_FILE"; then
        current_ports="$(effective_ssh_ports "$target_user" || true)"
        current_count="$(awk 'NF {count++} END {print count+0}' <<< "$current_ports")"
        (( current_count <= 1 )) && return 0
    fi
    return 1
}

write_ssh_dropin() {
    local port="$1" allow_root="$2" write_port="${3:-yes}"
    mkdir -p "$(dirname "$SSH_DROPIN_FILE")"
    {
        printf '# Managed by vps-tool. Generated: %s\n' "$(beijing_iso)"
        [[ "$write_port" == "yes" ]] && printf 'Port %s\n' "$port"
        cat <<EOF_SSH
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
    } > "$SSH_DROPIN_FILE"
    chmod 600 "$SSH_DROPIN_FILE"
}

verify_effective_ssh_config() {
    local port="$1" target_user="$2" effective effective_ports unique_ports raw_display
    sshd -t || return 1
    effective="$(sshd -T -C "user=${target_user},host=localhost,addr=127.0.0.1" 2>/dev/null)" || return 1
    effective_ports="$(awk '$1=="port" {print $2}' <<< "$effective")"
    unique_ports="$(unique_port_list <<< "$effective_ports")"
    raw_display="${effective_ports//$'\n'/,}"

    # OpenSSH 可能因多个配置文件重复输出同一个 Port；相同值去重后视为一个有效端口。
    if [[ "$unique_ports" != "$port" ]]; then
        log_error "有效 SSH 端口不是唯一的 ${port}（当前：${raw_display:-未检测到}）"
        return 1
    fi
    if [[ "$(awk 'NF {count++} END {print count+0}' <<< "$effective_ports")" -gt 1 ]]; then
        log_info "检测到重复的 Port ${port} 声明，已按同一端口跳过重复项"
    fi
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
    ui_section "01" "当前连接"
    ui_kv "SSH 服务" "$(ui_state "$(systemctl is-active "$SSH_SERVICE" 2>/dev/null || true)")"
    ui_kv "当前端口" "${C_BOLD}${C_CYAN}${CURRENT_SSH_PORT}${C_RESET}"

    local target_user default_port new_port root_policy backup_dir backup_file existed=0
    local port_changed=0 write_port="yes" rollback_firewall_kind="none"
    local skip_connection_test=0
    ui_subtitle "密钥认证"
    target_user="$(prompt_value '配置密钥登录的用户' "${SUDO_USER:-root}")"
    ensure_authorized_key "$target_user" "$CURRENT_SSH_PORT"

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
    if [[ "$NEW_SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
        port_changed=1
    else
        if ! should_write_ssh_port "$NEW_SSH_PORT" "$CURRENT_SSH_PORT" "$target_user"; then
            write_port="no"
        fi
        if ssh_key_only_login_is_effective "$target_user"; then
            skip_connection_test=1
        fi
    fi

    root_policy="prohibit-password"
    if [[ "$target_user" != "root" ]] && confirm "完全禁止 root SSH 登录" "Y"; then
        if ! id -nG "$target_user" | tr ' ' $'\n' | grep -qx 'sudo'; then
            log_error "用户 ${target_user} 不在 sudo 组中，拒绝禁用 root SSH 登录"
            return 1
        fi
        command_exists sudo || { log_error "系统未安装 sudo，拒绝禁用 root SSH 登录"; return 1; }
        root_policy="no"
    fi

    ui_section "02" "配置预览"
    ui_kv "目标用户" "$target_user"
    if (( port_changed == 1 )); then
        ui_kv "SSH 端口" "${CURRENT_SSH_PORT}  →  ${C_BOLD}${C_CYAN}${NEW_SSH_PORT}${C_RESET}"
    else
        ui_kv "SSH 端口" "${C_BOLD}${C_CYAN}${CURRENT_SSH_PORT}${C_RESET}  ${C_DIM}保持不变${C_RESET}"
    fi
    ui_kv "登录方式" "${C_GREEN}✔ 仅允许公钥${C_RESET}"
    ui_kv "root 策略" "$root_policy"
    if (( skip_connection_test == 1 )); then
        ui_kv "连接确认" "${C_GREEN}自动跳过（当前已为仅密钥登录）${C_RESET}"
        ui_kv "回滚保护" "${C_DIM}无需定时回滚${C_RESET}"
    else
        ui_kv "连接确认" "${C_YELLOW}需要在新终端确认${C_RESET}"
        ui_kv "回滚保护" "${SSH_ROLLBACK_TIMEOUT} 秒"
    fi
    printf '\n'
    confirm "确认继续" "Y" || { log_warn "已取消 SSH 配置"; return 0; }

    if (( port_changed == 1 )); then
        firewall_allow_ssh_port "$NEW_SSH_PORT" || { log_error "未确认新端口已放行，已停止"; return 1; }
        rollback_firewall_kind="$FIREWALL_KIND"
    else
        log_info "新端口与当前端口一致，跳过端口切换和防火墙变更"
    fi

    backup_dir="$(create_backup_dir)"
    backup_file="${backup_dir}/00-vps-tool.conf"
    if [[ -f "$SSH_DROPIN_FILE" ]]; then
        cp -a "$SSH_DROPIN_FILE" "$backup_file"
        existed=1
    fi

    write_ssh_dropin "$NEW_SSH_PORT" "$root_policy" "$write_port"
    if ! verify_effective_ssh_config "$NEW_SSH_PORT" "$target_user"; then
        log_error "SSH 配置检查失败，正在恢复"
        [[ "$existed" == "1" ]] && cp -a "$backup_file" "$SSH_DROPIN_FILE" || rm -f "$SSH_DROPIN_FILE"
        (( port_changed == 1 )) && firewall_remove_ssh_port "$NEW_SSH_PORT"
        return 1
    fi
    log_success "sshd 配置语法和有效参数检查通过"

    if (( skip_connection_test == 1 )); then
        if ! systemctl reload "$SSH_SERVICE"; then
            log_error "SSH 服务重新加载失败，正在恢复原配置"
            [[ "$existed" == "1" ]] && cp -a "$backup_file" "$SSH_DROPIN_FILE" || rm -f "$SSH_DROPIN_FILE"
            systemctl reload "$SSH_SERVICE" >/dev/null 2>&1 || true
            return 1
        fi
        sleep 1
        if ! ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${NEW_SSH_PORT}$"; then
            log_error "未检测到 SSH 继续监听端口 ${NEW_SSH_PORT}，正在恢复原配置"
            [[ "$existed" == "1" ]] && cp -a "$backup_file" "$SSH_DROPIN_FILE" || rm -f "$SSH_DROPIN_FILE"
            systemctl reload "$SSH_SERVICE" >/dev/null 2>&1 || true
            return 1
        fi
        printf 'SSH_PORT=%q\nSSH_USER=%q\nUPDATED_AT=%q\n' \
            "$NEW_SSH_PORT" "$target_user" "$(beijing_iso)" > "${APP_STATE_DIR}/ssh.conf"
        chmod 600 "${APP_STATE_DIR}/ssh.conf"
        log_success "当前端口未变化且仅密钥登录已生效，已跳过重复连接确认"
        log_success "SSH 安全配置已完成"
        return 0
    fi

    if ! schedule_ssh_rollback "$backup_file" "$existed" "$NEW_SSH_PORT" "$rollback_firewall_kind" "$SSH_SERVICE" "$SSH_ROLLBACK_TIMEOUT"; then
        log_error "无法创建 SSH 自动回滚任务，已恢复原配置"
        [[ "$existed" == "1" ]] && cp -a "$backup_file" "$SSH_DROPIN_FILE" || rm -f "$SSH_DROPIN_FILE"
        (( port_changed == 1 )) && firewall_remove_ssh_port "$NEW_SSH_PORT"
        return 1
    fi
    systemctl reload "$SSH_SERVICE"
    sleep 1
    ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${NEW_SSH_PORT}$" \
        || { log_error "未检测到 SSH 监听新端口，立即回滚"; run_ssh_rollback_now; return 1; }

    ui_section "03" "连接确认"
    ui_kv "新 SSH 端口" "${C_BOLD}${C_CYAN}${NEW_SSH_PORT}${C_RESET}"
    ui_kv "登录用户" "$target_user"
    printf '\n  %s请勿关闭当前窗口，请在另一终端执行：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %sssh -p %s %s@服务器IP%s\n' "$C_BOLD" "$NEW_SSH_PORT" "$target_user" "$C_RESET"
    printf '  %s新连接成功后返回当前窗口选择 Y；选择 N 将立即回滚。%s\n' "$C_DIM" "$C_RESET"


    if confirm "是否已使用新端口和密钥登录成功" "Y"; then
        if ! cancel_ssh_rollback "$NEW_SSH_PORT"; then
            log_error "自动回滚可能已经执行；不会删除旧端口规则。请重新运行 SSH 配置"
            return 1
        fi
        if [[ "$CURRENT_SSH_PORT" != "$NEW_SSH_PORT" ]]; then
            firewall_remove_ssh_port "$CURRENT_SSH_PORT"
        fi
        printf 'SSH_PORT=%q\nSSH_USER=%q\nUPDATED_AT=%q\n' \
            "$NEW_SSH_PORT" "$target_user" "$(beijing_iso)" > "${APP_STATE_DIR}/ssh.conf"
        chmod 600 "${APP_STATE_DIR}/ssh.conf"
        log_success "SSH 安全配置已完成"
        return 0
    fi

    run_ssh_rollback_now
    log_warn "已按选择恢复原 SSH 配置"
    return 1

}

show_ssh_status() {
    ssh_service_name
    detect_current_ssh_port
    local cfg root_cfg service_state pubkey password interactive
    local root_login root_password root_pubkey root_methods
    service_state="$(systemctl is-active "$SSH_SERVICE" 2>/dev/null || true)"
    cfg="$(sshd -T 2>/dev/null || true)"
    root_cfg="$(root_effective_config 2>/dev/null || true)"
    pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$cfg")"
    password="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$cfg")"
    interactive="$(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$cfg")"
    root_login="$(awk '$1=="permitrootlogin" {print $2; exit}' <<< "$root_cfg")"
    root_password="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$root_cfg")"
    root_pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$root_cfg")"
    root_methods="$(awk '$1=="authenticationmethods" {print $2; exit}' <<< "$root_cfg")"

    ui_kv "SSH 服务" "$(ui_state "$service_state")"
    ui_kv "有效端口" "${C_BOLD}${C_CYAN}${CURRENT_SSH_PORT}${C_RESET}"
    ui_kv "普通用户公钥" "$(ui_expect "${pubkey:-unknown}" yes)"
    ui_kv "普通用户密码" "$(ui_expect "${password:-unknown}" no)"
    ui_kv "交互式认证" "$(ui_expect "${interactive:-unknown}" no)"
    ui_kv "root 账户" "$(root_account_status_label)"
    ui_kv "root 登录 Shell" "$(root_login_shell)"
    ui_kv "root 登录策略" "${root_login:-unknown}"
    ui_kv "root 公钥认证" "${root_pubkey:-unknown}"
    ui_kv "root 密码认证" "${root_password:-unknown}"
    ui_kv "root 认证组合" "${root_methods:-unknown}"
    ui_kv "root 专用配置" "$(root_access_override_status)"
}
