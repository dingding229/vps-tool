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

ssh_user_effective_config() {
    local user="$1" port="$2" client_ip local_ip host=localhost
    read -r client_ip _ local_ip _ <<< "${SSH_CONNECTION:-}"
    if [[ "$client_ip" =~ ^[[:xdigit:].:]+$ && "$local_ip" =~ ^[[:xdigit:].:]+$ ]]; then
        host="$client_ip"
    else
        client_ip=127.0.0.1
        local_ip=127.0.0.1
    fi
    sshd -T -C "user=${user},host=${host},addr=${client_ip},laddr=${local_ip},lport=${port}" 2>/dev/null
}

ssh_key_only_login_is_effective() {
    local target_user="$1" effective password pubkey interactive methods permit_root
    effective="$(ssh_user_effective_config "$target_user" "$CURRENT_SSH_PORT")" || return 1
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
    if ssh_managed_port_exists "$current_port"; then
        current_ports="$(effective_ssh_ports "$target_user" || true)"
        current_count="$(awk 'NF {count++} END {print count+0}' <<< "$current_ports")"
        (( current_count <= 1 )) && return 0
    fi
    return 1
}

ssh_managed_port_exists() {
    local port="$1" file
    for file in "$SSH_DROPIN_FILE" "$SSH_LEGACY_DROPIN_FILE"; do
        if [[ -f "$file" ]] && awk -v wanted="$port" \
            'tolower($1)=="port" && $2==wanted {found=1} END {exit !found}' "$file"; then
            return 0
        fi
    done
    return 1
}

write_ssh_dropin() {
    local port="$1" allow_root="$2" write_port="${3:-yes}"
    mkdir -p "$(dirname "$SSH_DROPIN_FILE")" || return 1
    {
        printf '# Managed by vps-tool. Generated: %s\n' "$(beijing_iso)" || return 1
        if [[ "$write_port" == "yes" ]]; then printf 'Port %s\n' "$port" || return 1; fi
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
    } > "$SSH_DROPIN_FILE" || return 1
    chmod 600 "$SSH_DROPIN_FILE"
}

ensure_ssh_security_include() {
    local remove_root="$1" temp_file
    temp_file="$(mktemp "${SSHD_MAIN_CONFIG}.vps-tool.XXXXXX")" || return 1
    if cp -a -- "$SSHD_MAIN_CONFIG" "$temp_file" \
        && awk -v managed="$SSH_DROPIN_FILE" -v legacy="$SSH_LEGACY_DROPIN_FILE" \
            -v root_override="$ROOT_SSH_DROPIN_FILE" -v remove_root="$remove_root" '
        NR==1 {
            if (!remove_root && $0=="Include " root_override) {print; print "Include " managed; next}
            print "Include " managed
        }
        tolower($1)=="include" && (NF==2 || $3 ~ /^#/) &&
            ($2==managed || $2==legacy || (remove_root && $2==root_override)) {next}
        {print}
        END {if (!NR) print "Include " managed}
    ' "$SSHD_MAIN_CONFIG" > "$temp_file"; then
        if ! cmp -s "$temp_file" "$SSHD_MAIN_CONFIG"; then
            mv -f -- "$temp_file" "$SSHD_MAIN_CONFIG" && return 0
        else
            rm -f -- "$temp_file"
            return 0
        fi
    fi
    rm -f -- "$temp_file"
    return 1
}

ssh_config_is_managed() {
    [[ -f "$1" && ! -L "$1" ]] && grep -q '^# Managed by vps-tool\. Generated:' "$1"
}

apply_ssh_security_config() {
    local port="$1" root_policy="$2" write_port="$3" remove_root="$4"
    write_ssh_dropin "$port" "$root_policy" "$write_port" \
        && ensure_ssh_security_include "$remove_root" \
        && rm -f -- "$SSH_LEGACY_DROPIN_FILE" || return 1
    if (( remove_root == 1 )); then
        rm -f -- "$ROOT_SSH_DROPIN_FILE" || return 1
    fi
}

verify_ssh_auth_setting() {
    local config="$1" label="$2" expected="$3" scope="$4" effective
    effective="$(awk -v key="$label" '$1==tolower(key) {$1=""; sub(/^ /, ""); print; exit}' <<< "$config")"
    if [[ "$effective" != "$expected" ]]; then
        log_error "${label} 未生效（${scope}，实际：${effective:-未检测到}，期望：${expected}）"
        return 1
    fi
}

verify_effective_ssh_config() {
    local port="$1" target_user="$2" root_policy="${3:-}" effective effective_ports unique_ports raw_display
    local setting expected scope="用户 ${target_user}"
    sshd -t || return 1
    effective="$(ssh_user_effective_config "$target_user" "$port")" \
        || { log_error "无法读取 ${target_user} 的 SSH 生效配置"; return 1; }
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
    for setting in PasswordAuthentication KbdInteractiveAuthentication PubkeyAuthentication AuthenticationMethods; do
        case "$setting" in
            PubkeyAuthentication) expected=yes ;;
            AuthenticationMethods) expected=publickey ;;
            *) expected=no ;;
        esac
        if ! verify_ssh_auth_setting "$effective" "$setting" "$expected" "$scope"; then
            log_warn "请检查是否有匹配 ${target_user} 的 Match 规则覆盖了认证设置"
            return 1
        fi
    done
    if [[ "$target_user" == root && "$root_policy" == prohibit-password ]]; then
        verify_ssh_auth_setting "$effective" PermitRootLogin prohibit-password "$scope" || return 1
    elif [[ "$root_policy" == no ]]; then
        effective="$(ssh_user_effective_config root "$port")" || return 1
        verify_ssh_auth_setting "$effective" PermitRootLogin no '用户 root' || return 1
    fi
}

ssh_key_rotation_port() {
    local user="$1" ports port session_port
    session_port="$(awk '{print $4; exit}' <<< "${SSH_CONNECTION:-}")"
    if [[ "$session_port" =~ ^[1-9][0-9]{0,4}$ ]] && validate_port "$session_port"; then
        printf '%s' "$session_port"
        return
    fi

    ports="$(effective_ssh_ports "$user" | unique_port_list)" || return 1
    [[ -n "$ports" ]] || return 1
    if [[ "$ports" != *$'\n'* ]]; then
        validate_port "$ports" || return 1
        printf '%s' "$ports"
        return
    fi

    while true; do
        port="$(prompt_value "登录测试使用的现有端口（${ports//$'\n'/、}）" "${ports%%$'\n'*}")" || return 1
        if grep -Fxq -- "$port" <<< "$ports" && validate_port "$port"; then
            printf '%s' "$port"
            return
        fi
        log_warn "请选择已配置的 SSH 端口" >&2
    done
}

rotate_ssh_key_interactive() {
    ui_header
    ui_title "更换 SSH 密钥"
    local required_cmd user port
    for required_cmd in sshd ssh-keygen; do
        command_exists "$required_cmd" || { log_error "缺少必要命令：${required_cmd}"; return 1; }
    done

    ui_section "01" "目标账户"
    user="$(prompt_value '更换 SSH 密钥的用户' "${SUDO_USER:-root}")" || return 1
    if ! id "$user" >/dev/null 2>&1; then
        log_error "用户不存在：${user}"
        return 1
    fi
    resolve_target_user "$user" || return 1
    if [[ -L "${TARGET_HOME}/.ssh" || -L "$TARGET_AUTH_KEYS" || ! -f "$TARGET_AUTH_KEYS" ]] \
        || ! has_valid_authorized_key; then
        log_warn "未检测到可换新的公钥文件：${TARGET_AUTH_KEYS}"
        return 1
    fi
    if ! authorized_keys_are_plain "$TARGET_AUTH_KEYS"; then
        log_warn "公钥文件含限制选项或非标准授权条目，为保留现有访问限制，未执行换新"
        return 1
    fi

    port="$(ssh_key_rotation_port "$user")" || { log_error "未能确定用于测试的 SSH 端口"; return 1; }
    ui_kv "目标用户" "$user"
    ui_kv "测试端口" "$port"
    ui_kv "替换范围" "$TARGET_AUTH_KEYS"
    log_info "只更换公钥，不修改 SSH 端口、登录策略或防火墙"
    log_warn "请保持当前连接，确认能用新私钥登录后再移除旧公钥"
    if ! confirm "是否生成新的 Ed25519 密钥"; then
        log_info "已保留原有 SSH 密钥"
        return 1
    fi
    generate_authorized_key "$port" rotate plain
}

finish_ssh_security_config() {
    local user="$1" remove_root="$2"
    if (( remove_root == 1 )); then
        rm -f -- "${APP_STATE_DIR}/root-login.conf" || log_warn "无法清理旧的 root 专用策略状态"
    fi
    printf 'SSH_PORT=%q\nSSH_USER=%q\nUPDATED_AT=%q\n' \
        "$NEW_SSH_PORT" "$user" "$(beijing_iso)" > "${APP_STATE_DIR}/ssh.conf" \
        && chmod 600 "${APP_STATE_DIR}/ssh.conf" || log_warn "无法保存 SSH 配置状态"
    log_success "SSH 安全配置已完成"
}

configure_ssh_interactive() {
    ui_header
    ui_title "SSH 安全配置"
    local required_cmd file
    for required_cmd in sshd ss systemctl systemd-run flock ssh-keygen; do
        command_exists "$required_cmd" || { log_error "缺少必要命令：${required_cmd}"; return 1; }
    done
    [[ ! -e "$SSH_ROLLBACK_STATE" && -z "${SSH_PENDING_BACKUP:-}" ]] \
        || { log_warn "已有待处理的 SSH 配置，请先完成确认或执行回滚"; return 1; }
    for file in "$SSH_DROPIN_FILE" "$SSH_LEGACY_DROPIN_FILE"; do
        if [[ -e "$file" || -L "$file" ]] && ! ssh_config_is_managed "$file"; then
            log_error "配置文件不由 VPS Tool 管理，未覆盖：${file}"
            return 1
        fi
    done
    ssh_service_name
    detect_current_ssh_port
    ui_section "01" "当前连接"
    ui_kv "SSH 服务" "$(ui_state "$(systemctl is-active "$SSH_SERVICE" 2>/dev/null || true)")"
    ui_kv "当前端口" "${C_BOLD}${C_CYAN}${CURRENT_SSH_PORT}${C_RESET}"

    local target_user default_port new_port root_policy backup_dir
    local port_changed=0 write_port="yes" rollback_firewall_kind="none"
    local skip_connection_test=0 remove_root_override=0 preserve_managed_port=0 root_preview
    local -a config_paths=("$SSHD_MAIN_CONFIG" "$SSH_DROPIN_FILE" "$SSH_LEGACY_DROPIN_FILE")
    ui_subtitle "密钥认证"
    target_user="$(prompt_value '配置密钥登录的用户' "${SUDO_USER:-root}")" || return 1
    ensure_authorized_key "$target_user" "$CURRENT_SSH_PORT" || return 1

    default_port="$(random_ssh_port)"
    while true; do
        new_port="$(prompt_value '新的 SSH 端口' "$default_port")" || return 1
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
            if ssh_managed_port_exists "$CURRENT_SSH_PORT"; then preserve_managed_port=1; fi
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
    root_preview="$root_policy"
    if ssh_config_is_managed "$ROOT_SSH_DROPIN_FILE"; then
        if [[ "$root_policy" == no ]] || { [[ "$target_user" == root ]] \
            && ( ! grep -Eq '^[[:space:]]*PasswordAuthentication[[:space:]]+no[[:space:]]*$' "$ROOT_SSH_DROPIN_FILE" \
                || [[ "$(root_effective_setting permitrootlogin)" != prohibit-password ]] ); }; then
            remove_root_override=1
            config_paths+=("$ROOT_SSH_DROPIN_FILE")
            root_preview="${root_policy}（移除原 VPS Tool root 专用规则）"
            skip_connection_test=0
        elif [[ "$target_user" != root ]]; then
            root_preview="保留原 VPS Tool root 专用规则"
        fi
    fi
    if [[ "$root_policy" == no && "$(root_effective_setting permitrootlogin)" != no ]]; then
        skip_connection_test=0
    fi

    ui_section "02" "配置预览"
    ui_kv "目标用户" "$target_user"
    if (( port_changed == 1 )); then
        ui_kv "SSH 端口" "${CURRENT_SSH_PORT}  →  ${C_BOLD}${C_CYAN}${NEW_SSH_PORT}${C_RESET}"
    else
        ui_kv "SSH 端口" "${C_BOLD}${C_CYAN}${CURRENT_SSH_PORT}${C_RESET}  ${C_DIM}保持不变${C_RESET}"
    fi
    ui_kv "登录方式" "${C_GREEN}✔ 仅允许公钥${C_RESET}"
    ui_kv "root 策略" "$root_preview"
    if (( skip_connection_test == 1 )); then
        ui_kv "连接确认" "${C_GREEN}自动跳过（当前已为仅密钥登录）${C_RESET}"
        ui_kv "回滚保护" "${C_DIM}无需定时回滚${C_RESET}"
    else
        ui_kv "连接确认" "${C_YELLOW}需要在新终端确认${C_RESET}"
        ui_kv "回滚保护" "${SSH_ROLLBACK_TIMEOUT} 秒"
    fi
    printf '\n'
    confirm "确认继续" "Y" || { log_warn "已取消 SSH 配置"; return 0; }

    [[ -f "$SSHD_MAIN_CONFIG" ]] || { log_error "找不到 ${SSHD_MAIN_CONFIG}"; return 1; }
    backup_dir="$(mktemp -d "${APP_BACKUP_DIR}/ssh-$(beijing_compact).XXXXXX")" \
        && backup_ssh_config_snapshot "$backup_dir" "${config_paths[@]}" \
        || { log_error "无法备份 SSH 配置，未应用策略"; return 1; }
    SSH_PENDING_BACKUP="$backup_dir"
    SSH_PENDING_PORT="$NEW_SSH_PORT"
    if (( port_changed == 1 )); then
        if ! firewall_allow_ssh_port "$NEW_SSH_PORT"; then
            clear_pending_ssh_config
            log_error "未确认新端口已放行，已停止"
            return 1
        fi
        rollback_firewall_kind="$FIREWALL_KIND"
        SSH_PENDING_FIREWALL="$rollback_firewall_kind"
    else
        log_info "新端口与当前端口一致，跳过端口切换和防火墙变更"
    fi

    if ! apply_ssh_security_config "$NEW_SSH_PORT" "$root_policy" "$write_port" "$remove_root_override"; then
        log_error "无法写入 SSH 配置，正在恢复"
        cleanup_pending_ssh_config
        return 1
    fi

    # 旧托管文件被重复 Include 时，重复端口可能实际只有一个来源。迁移后必须保留它。
    if (( preserve_managed_port == 1 )) \
        && ! effective_ssh_ports "$target_user" | grep -Fxq -- "$NEW_SSH_PORT"; then
        if ! write_ssh_dropin "$NEW_SSH_PORT" "$root_policy" yes; then
            log_error "无法保留当前 SSH 端口，正在恢复"
            cleanup_pending_ssh_config
            return 1
        fi
    fi
    if ! verify_effective_ssh_config "$NEW_SSH_PORT" "$target_user" "$root_policy"; then
        log_error "SSH 配置检查失败，正在恢复"
        cleanup_pending_ssh_config
        return 1
    fi
    log_success "sshd 配置语法和有效参数检查通过"

    if (( skip_connection_test == 1 )); then
        SSH_PENDING_RELOAD=1
        if ! systemctl reload "$SSH_SERVICE"; then
            log_error "SSH 服务重新加载失败，正在恢复原配置"
            cleanup_pending_ssh_config
            return 1
        fi
        sleep 1
        if ! ss -lntH | awk '{print $4}' | grep -Eq "(^|:)${NEW_SSH_PORT}$"; then
            log_error "未检测到 SSH 继续监听端口 ${NEW_SSH_PORT}，正在恢复原配置"
            cleanup_pending_ssh_config
            return 1
        fi
        clear_pending_ssh_config
        log_success "当前端口未变化且仅密钥登录已生效，已跳过重复连接确认"
        finish_ssh_security_config "$target_user" "$remove_root_override"
        return
    fi

    if ! schedule_ssh_rollback "$backup_dir" "$NEW_SSH_PORT" "$rollback_firewall_kind" "$SSH_SERVICE" "$SSH_ROLLBACK_TIMEOUT"; then
        log_error "无法创建 SSH 自动回滚任务，正在恢复原配置"
        cleanup_pending_ssh_config
        return 1
    fi
    clear_pending_ssh_config
    if ! systemctl reload "$SSH_SERVICE"; then
        log_error "SSH 服务重新加载失败，立即回滚"
        run_ssh_rollback_now
        return 1
    fi
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
        finish_ssh_security_config "$target_user" "$remove_root_override"
        return 0
    fi

    if run_ssh_rollback_now; then log_warn "已按选择恢复原 SSH 配置"; fi
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
