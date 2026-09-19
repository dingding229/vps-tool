#!/usr/bin/env bash

ROOT_ACCESS_MODE=""
ROOT_NONROOT_PROBE=""
ROOT_NONROOT_BASELINE=""
ROOT_LOGIN_TRANSACTION_ACTIVE=0
ROOT_LOGIN_TRANSACTION_BACKUP=""
ROOT_LOGIN_TRANSACTION_SERVICE=""

root_account_status() {
    passwd -S root 2>/dev/null | awk '{print $2}'
}

root_account_status_label() {
    local account_status
    account_status="$(root_account_status)"
    case "$account_status" in
        P) printf '%s✔ 已启用%s' "$C_GREEN" "$C_RESET" ;;
        L|LK) printf '%s● 已锁定%s' "$C_YELLOW" "$C_RESET" ;;
        NP) printf '%s▲ 无密码%s' "$C_RED" "$C_RESET" ;;
        *) printf '%s● %s%s' "$C_YELLOW" "${account_status:-unknown}" "$C_RESET" ;;
    esac
}

root_login_shell() {
    getent passwd root 2>/dev/null | cut -d: -f7
}

root_effective_config() {
    sshd -T -C 'user=root,host=localhost,addr=127.0.0.1' 2>/dev/null
}

root_effective_setting() {
    local keyword="$1"
    root_effective_config | awk -v key="$keyword" '$1==key {print $2; exit}'
}

root_access_override_status() {
    if [[ -f "$ROOT_SSH_DROPIN_FILE" ]] \
        && [[ "$(head -n 1 "$SSHD_MAIN_CONFIG" 2>/dev/null)" == "Include ${ROOT_SSH_DROPIN_FILE}" ]]; then
        printf '%s✔ 已启用%s' "$C_GREEN" "$C_RESET"
    else
        printf '%s● 未启用%s' "$C_DIM" "$C_RESET"
    fi
}

root_access_control_summary() {
    local effective key value output=""
    effective="$(root_effective_config || true)"
    for key in allowusers denyusers allowgroups denygroups; do
        value="$(awk -v wanted="$key" '$1==wanted {$1=""; sub(/^[[:space:]]+/, ""); print; exit}' <<< "$effective")"
        [[ -n "$value" ]] || continue
        output+="${key}=${value}; "
    done
    printf '%s' "${output%; }"
}

root_nonroot_probe_user() {
    local candidate
    for candidate in "${SUDO_USER:-}" "${SSH_USER:-}" nobody; do
        [[ -n "$candidate" && "$candidate" != "root" ]] || continue
        if id "$candidate" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "root" {print $1; exit}'
}

ssh_auth_fingerprint_for_user() {
    local user="$1"
    sshd -T -C "user=${user},host=localhost,addr=127.0.0.1" 2>/dev/null \
        | awk '$1 ~ /^(pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|authenticationmethods)$/ {print}'
}

capture_nonroot_ssh_baseline() {
    ROOT_NONROOT_PROBE="$(root_nonroot_probe_user)"
    ROOT_NONROOT_BASELINE=""
    [[ -n "$ROOT_NONROOT_PROBE" ]] || return 0
    ROOT_NONROOT_BASELINE="$(ssh_auth_fingerprint_for_user "$ROOT_NONROOT_PROBE")"
}

copy_sudo_user_keys_to_root() {
    local source_user="${SUDO_USER:-}" source_home source_keys line copied=0
    [[ -n "$source_user" && "$source_user" != "root" ]] || return 1
    id "$source_user" >/dev/null 2>&1 || return 1
    source_home="$(getent passwd "$source_user" | cut -d: -f6)"
    source_keys="${source_home}/.ssh/authorized_keys"
    [[ -s "$source_keys" ]] || return 1
    awk '!/^[[:space:]]*(#|$)/ && $1 ~ /^(ssh-|ecdsa-|sk-)/' "$source_keys" | grep -q . || return 1

    confirm "是否复用当前用户 ${source_user} 的 SSH 公钥用于 root" "Y" || return 1
    resolve_target_user root
    fix_authorized_keys_permissions
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if ! grep -qxF -- "$line" "$TARGET_AUTH_KEYS"; then
            printf '%s\n' "$line" >> "$TARGET_AUTH_KEYS"
            copied=1
        fi
    done < <(awk '!/^[[:space:]]*(#|$)/ && $1 ~ /^(ssh-|ecdsa-|sk-)/' "$source_keys")
    fix_authorized_keys_permissions
    if has_valid_authorized_key; then
        if (( copied == 1 )); then
            log_success "已将 ${source_user} 的公钥复制到 root"
        else
            log_success "root 已存在相同公钥"
        fi
        return 0
    fi
    return 1
}

prepare_root_key_access() {
    resolve_target_user root
    fix_authorized_keys_permissions
    if has_valid_authorized_key; then
        log_success "检测到 root 已有有效 SSH 公钥"
        ssh-keygen -lf "$TARGET_AUTH_KEYS" 2>/dev/null | sed 's/^/    /' || true
    elif ! copy_sudo_user_keys_to_root; then
        ensure_authorized_key root "$CURRENT_SSH_PORT" deferred || return 1
    fi
}

unlock_root_for_key_access() {
    local account_status random_password
    account_status="$(root_account_status)"
    [[ "$account_status" == "L" || "$account_status" == "LK" ]] || return 0

    if command_exists openssl; then
        random_password="$(openssl rand -base64 48)"
    elif command_exists python3; then
        random_password="$(python3 - <<'PY_RANDOM'
import secrets
print(secrets.token_urlsafe(48))
PY_RANDOM
)"
    elif command_exists base64; then
        random_password="$(head -c 48 /dev/urandom | base64 | tr -d '\n')"
    else
        log_error "缺少 openssl、python3 或 base64，无法安全解锁 root 账户"
        return 1
    fi
    printf 'root:%s\n' "$random_password" | chpasswd \
        || { unset random_password; log_error "无法解锁 root 账户"; return 1; }
    unset random_password
    log_success "root 账户已解锁；随机密码已丢弃，SSH 仍仅允许密钥认证"
}

prepare_root_password_access() {
    printf '\n%s请为 root 设置强密码。输入内容不会显示。%s\n' "$C_YELLOW" "$C_RESET"
    passwd root || { log_error "root 密码设置失败"; return 1; }
    [[ "$(root_account_status)" == "P" ]] \
        || { log_error "root 账户仍未处于可用状态"; return 1; }
    log_success "root 密码已设置"
}

ensure_root_login_shell() {
    local current_shell
    current_shell="$(root_login_shell)"
    case "$current_shell" in
        */nologin|*/false|"")
            usermod -s /bin/bash root || { log_error "无法将 root Shell 设置为 /bin/bash"; return 1; }
            log_success "root 登录 Shell 已设置为 /bin/bash"
            ;;
    esac
}

backup_root_login_state() {
    local backup_dir="$1" root_home root_keys
    mkdir -p "$backup_dir"
    cp -a "$SSHD_MAIN_CONFIG" "${backup_dir}/sshd_config" || return 1
    if [[ -f "$ROOT_SSH_DROPIN_FILE" ]]; then
        cp -a "$ROOT_SSH_DROPIN_FILE" "${backup_dir}/root-access.conf" || return 1
        : > "${backup_dir}/root-access.existed" || return 1
    fi

    getent shadow root > "${backup_dir}/root-shadow-entry" || return 1
    [[ -s "${backup_dir}/root-shadow-entry" ]] || return 1
    chmod 600 "${backup_dir}/root-shadow-entry"
    root_login_shell > "${backup_dir}/root-shell" || return 1
    [[ -s "${backup_dir}/root-shell" ]] || return 1

    root_home="$(getent passwd root | cut -d: -f6)"
    root_keys="${root_home}/.ssh/authorized_keys"
    if [[ -f "$root_keys" ]]; then
        cp -a "$root_keys" "${backup_dir}/root-authorized_keys" || return 1
        : > "${backup_dir}/root-authorized-keys.existed" || return 1
    fi
}

restore_root_login_state() {
    local backup_dir="$1" root_home root_keys shadow_entry password_hash last_change original_shell

    [[ -f "${backup_dir}/sshd_config" ]] \
        && cp -a "${backup_dir}/sshd_config" "$SSHD_MAIN_CONFIG"
    if [[ -f "${backup_dir}/root-access.existed" && -f "${backup_dir}/root-access.conf" ]]; then
        cp -a "${backup_dir}/root-access.conf" "$ROOT_SSH_DROPIN_FILE"
    else
        rm -f -- "$ROOT_SSH_DROPIN_FILE"
    fi

    if [[ -s "${backup_dir}/root-shadow-entry" ]]; then
        shadow_entry="$(cat "${backup_dir}/root-shadow-entry")"
        password_hash="$(cut -d: -f2 <<< "$shadow_entry")"
        last_change="$(cut -d: -f3 <<< "$shadow_entry")"
        usermod -p "$password_hash" root >/dev/null 2>&1 || true
        if [[ "$last_change" =~ ^-?[0-9]+$ ]]; then
            chage -d "$last_change" root >/dev/null 2>&1 || true
        fi
    fi

    original_shell="$(cat "${backup_dir}/root-shell" 2>/dev/null || true)"
    [[ -n "$original_shell" ]] && usermod -s "$original_shell" root >/dev/null 2>&1 || true

    root_home="$(getent passwd root | cut -d: -f6)"
    root_keys="${root_home}/.ssh/authorized_keys"
    if [[ -f "${backup_dir}/root-authorized-keys.existed" && -f "${backup_dir}/root-authorized_keys" ]]; then
        mkdir -p "${root_home}/.ssh"
        cp -a "${backup_dir}/root-authorized_keys" "$root_keys"
    else
        rm -f -- "$root_keys"
    fi
    cleanup_generated_private_key
}

begin_root_login_transaction() {
    ROOT_LOGIN_TRANSACTION_BACKUP="$1"
    ROOT_LOGIN_TRANSACTION_SERVICE="${2:-}"
    ROOT_LOGIN_TRANSACTION_ACTIVE=1
}

commit_root_login_transaction() {
    ROOT_LOGIN_TRANSACTION_ACTIVE=0
    ROOT_LOGIN_TRANSACTION_BACKUP=""
    ROOT_LOGIN_TRANSACTION_SERVICE=""
}

rollback_root_login_transaction() {
    local backup_dir="${ROOT_LOGIN_TRANSACTION_BACKUP:-}"
    local service="${ROOT_LOGIN_TRANSACTION_SERVICE:-}"
    ROOT_LOGIN_TRANSACTION_ACTIVE=0
    ROOT_LOGIN_TRANSACTION_BACKUP=""
    ROOT_LOGIN_TRANSACTION_SERVICE=""
    [[ -n "$backup_dir" && -d "$backup_dir" ]] || return 0
    restore_root_login_state "$backup_dir"
    if sshd -t >/dev/null 2>&1 && [[ -n "$service" ]]; then
        systemctl reload "$service" >/dev/null 2>&1 || true
    fi
}

cleanup_pending_root_login() {
    if (( ROOT_LOGIN_TRANSACTION_ACTIVE == 1 )); then
        log_warn "检测到未完成的 root 登录配置，正在自动恢复"
        rollback_root_login_transaction
    fi
}

write_root_access_dropin() {
    local mode="$1"
    mkdir -p "$(dirname "$ROOT_SSH_DROPIN_FILE")"
    if [[ "$mode" == "key" ]]; then
        cat > "$ROOT_SSH_DROPIN_FILE" <<EOF_ROOT
# Managed by vps-tool. Generated: $(beijing_iso) (${APP_TIMEZONE_LABEL:-北京时间})
Match User root
    PermitRootLogin prohibit-password
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
Match all
EOF_ROOT
    else
        cat > "$ROOT_SSH_DROPIN_FILE" <<EOF_ROOT
# Managed by vps-tool. Generated: $(beijing_iso) (${APP_TIMEZONE_LABEL:-北京时间})
Match User root
    PermitRootLogin yes
    PubkeyAuthentication yes
    PasswordAuthentication yes
    KbdInteractiveAuthentication no
    AuthenticationMethods any
Match all
EOF_ROOT
    fi
    (( EUID == 0 )) && chown root:root "$ROOT_SSH_DROPIN_FILE"
    chmod 644 "$ROOT_SSH_DROPIN_FILE"
}

ensure_root_access_include_first() {
    local include_line="Include ${ROOT_SSH_DROPIN_FILE}" temp_file
    [[ -f "$SSHD_MAIN_CONFIG" ]] || { log_error "找不到 ${SSHD_MAIN_CONFIG}"; return 1; }
    if [[ "$(head -n 1 "$SSHD_MAIN_CONFIG")" == "$include_line" ]]; then
        return 0
    fi

    temp_file="$(mktemp)" || return 1
    if ! {
        printf '%s\n' "$include_line"
        grep -vFx -- "$include_line" "$SSHD_MAIN_CONFIG" || true
    } > "$temp_file"; then
        rm -f -- "$temp_file"
        return 1
    fi
    # 直接写回现有 inode，以保留原 sshd_config 的所有者、权限和安全上下文。
    if ! cat "$temp_file" > "$SSHD_MAIN_CONFIG"; then
        rm -f -- "$temp_file"
        return 1
    fi
    rm -f -- "$temp_file"
}

verify_root_access_config() {
    local mode="$1" effective permit_root password pubkey interactive methods after_nonroot
    sshd -t || return 1
    effective="$(root_effective_config)" || return 1
    permit_root="$(awk '$1=="permitrootlogin" {print $2; exit}' <<< "$effective")"
    password="$(awk '$1=="passwordauthentication" {print $2; exit}' <<< "$effective")"
    pubkey="$(awk '$1=="pubkeyauthentication" {print $2; exit}' <<< "$effective")"
    interactive="$(awk '$1=="kbdinteractiveauthentication" {print $2; exit}' <<< "$effective")"
    methods="$(awk '$1=="authenticationmethods" {print $2; exit}' <<< "$effective")"

    if [[ "$mode" == "key" ]]; then
        [[ "$permit_root" == "prohibit-password" && "$password" == "no" \
            && "$pubkey" == "yes" && "$interactive" == "no" && "$methods" == "publickey" ]] \
            || return 1
    else
        [[ "$permit_root" == "yes" && "$password" == "yes" \
            && "$pubkey" == "yes" && "$interactive" == "no" && "$methods" == "any" ]] \
            || return 1
    fi

    if [[ -n "$ROOT_NONROOT_PROBE" && -n "$ROOT_NONROOT_BASELINE" ]]; then
        after_nonroot="$(ssh_auth_fingerprint_for_user "$ROOT_NONROOT_PROBE")"
        [[ "$after_nonroot" == "$ROOT_NONROOT_BASELINE" ]] || {
            log_error "root 专用配置意外改变了用户 ${ROOT_NONROOT_PROBE} 的认证策略"
            return 1
        }
    fi
}

enable_root_login_interactive() {
    ui_header
    ui_title "启用 root SSH 登录"
    ssh_service_name
    detect_current_ssh_port

    ui_section "01" "当前状态"
    ui_kv "SSH 端口" "${C_BOLD}${C_CYAN}${CURRENT_SSH_PORT}${C_RESET}"
    ui_kv "root 账户" "$(root_account_status_label)"
    ui_kv "登录 Shell" "$(root_login_shell)"
    ui_kv "root 登录策略" "$(root_effective_setting permitrootlogin)"
    ui_kv "root 密码认证" "$(root_effective_setting passwordauthentication)"
    ui_kv "root 公钥认证" "$(root_effective_setting pubkeyauthentication)"
    ui_kv "专用覆盖配置" "$(root_access_override_status)"

    local access_controls backup_dir
    access_controls="$(root_access_control_summary)"
    if [[ -n "$access_controls" ]]; then
        ui_kv "访问控制规则" "$access_controls"
        log_warn "AllowUsers / DenyUsers / AllowGroups / DenyGroups 可能继续限制 root 登录"
        confirm "是否继续配置并通过实际登录确认" "Y" || { log_warn "已取消"; return 0; }
    fi

    backup_dir="$(create_backup_dir)"
    backup_root_login_state "$backup_dir" || { log_error "无法备份 root 登录状态"; return 1; }
    begin_root_login_transaction "$backup_dir" "$SSH_SERVICE"

    ui_section "02" "认证方式"
    if confirm "是否使用更安全的 root 密钥登录" "Y"; then
        ROOT_ACCESS_MODE="key"
        if ! prepare_root_key_access; then
            rollback_root_login_transaction
            return 1
        fi
    else
        ROOT_ACCESS_MODE="password"
        if ! confirm "是否确认启用 root 密码登录" "Y"; then
            rollback_root_login_transaction
            log_warn "已取消"
            return 0
        fi
    fi

    ui_section "03" "配置预览"
    ui_kv "登录用户" "root"
    ui_kv "SSH 端口" "$CURRENT_SSH_PORT"
    if [[ "$ROOT_ACCESS_MODE" == "key" ]]; then
        ui_kv "认证方式" "${C_GREEN}✔ 仅密钥登录${C_RESET}"
        ui_kv "密码登录" "${C_GREEN}关闭${C_RESET}"
        ui_kv "锁定账户处理" "${C_DIM}使用随机强密码解锁并立即丢弃密码${C_RESET}"
    else
        ui_kv "认证方式" "${C_YELLOW}密码或公钥${C_RESET}"
        ui_kv "密码登录" "${C_YELLOW}仅对 root 启用${C_RESET}"
        ui_kv "安全提示" "${C_RED}请同时启用 Fail2ban 并使用强密码${C_RESET}"
    fi
    if ! confirm "是否应用 root SSH 登录配置" "Y"; then
        rollback_root_login_transaction
        log_warn "已取消，所有准备性修改已恢复"
        return 0
    fi

    capture_nonroot_ssh_baseline
    if [[ "$ROOT_ACCESS_MODE" == "key" ]]; then
        unlock_root_for_key_access || {
            rollback_root_login_transaction
            return 1
        }
    else
        prepare_root_password_access || {
            rollback_root_login_transaction
            return 1
        }
    fi
    ensure_root_login_shell || {
        rollback_root_login_transaction
        return 1
    }

    write_root_access_dropin "$ROOT_ACCESS_MODE"
    ensure_root_access_include_first || {
        rollback_root_login_transaction
        return 1
    }
    if ! verify_root_access_config "$ROOT_ACCESS_MODE"; then
        log_error "root SSH 配置检查失败，正在恢复原配置"
        rollback_root_login_transaction
        return 1
    fi
    if ! systemctl reload "$SSH_SERVICE"; then
        log_error "SSH 服务重新加载失败，正在恢复"
        rollback_root_login_transaction
        return 1
    fi

    ui_section "04" "登录确认"
    printf '  %s请保持当前窗口，在另一终端执行：%s\n' "$C_YELLOW" "$C_RESET"
    printf '  %sssh -p %s root@服务器IP%s\n' "$C_BOLD" "$CURRENT_SSH_PORT" "$C_RESET"
    printf '  %s登录成功后选择 Y；选择 N 会恢复 SSH 配置、root 密码状态、Shell 和公钥文件。%s\n' \
        "$C_DIM" "$C_RESET"
    if confirm "是否已成功登录 root" "Y"; then
        if [[ -n "${GENERATED_PRIVATE_KEY:-}" ]]; then
            GENERATED_KEY_CONFIRMED=1
            cleanup_generated_private_key
            log_success "服务器端临时私钥已删除，仅保留 root 公钥"
        fi
        cat > "${APP_STATE_DIR}/root-login.conf" <<EOF_STATE
MODE=$(printf '%q' "$ROOT_ACCESS_MODE")
SSH_PORT=$(printf '%q' "$CURRENT_SSH_PORT")
UPDATED_AT=$(printf '%q' "$(beijing_iso)")
TIMEZONE=$(printf '%q' "${APP_TIMEZONE:-Asia/Shanghai}")
EOF_STATE
        chmod 600 "${APP_STATE_DIR}/root-login.conf"
        commit_root_login_transaction
        log_success "root SSH 登录已启用"
        return 0
    fi

    rollback_root_login_transaction
    log_warn "root SSH 登录配置及账户状态已恢复"
    return 1
}
