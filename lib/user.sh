#!/usr/bin/env bash

TARGET_USER="root"
TARGET_HOME="/root"
TARGET_AUTH_KEYS="/root/.ssh/authorized_keys"
GENERATED_PRIVATE_KEY=""
GENERATED_PUBLIC_KEY_LINE=""
GENERATED_KEY_CONFIRMED=0

resolve_target_user() {
    local requested="${1:-root}"
    id "$requested" >/dev/null 2>&1 || die "用户不存在：${requested}"
    TARGET_USER="$requested"
    TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
    [[ -n "$TARGET_HOME" && -d "$TARGET_HOME" ]] || die "无法确定用户主目录：${TARGET_USER}"
    TARGET_AUTH_KEYS="${TARGET_HOME}/.ssh/authorized_keys"
}

fix_authorized_keys_permissions() {
    local group
    group="$(id -gn "$TARGET_USER")"
    mkdir -p "${TARGET_HOME}/.ssh"
    touch "$TARGET_AUTH_KEYS"
    chown "$TARGET_USER:$group" "${TARGET_HOME}/.ssh" "$TARGET_AUTH_KEYS"
    chmod 700 "${TARGET_HOME}/.ssh"
    chmod 600 "$TARGET_AUTH_KEYS"
}

has_valid_authorized_key() {
    [[ -s "$TARGET_AUTH_KEYS" ]] || return 1
    awk '!/^[[:space:]]*(#|$)/ && $1 ~ /^(ssh-|ecdsa-|sk-)/ {found=1} END {exit !found}' "$TARGET_AUTH_KEYS"
}

validate_public_key_line() {
    local key="$1" tmp
    [[ "$key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]+[A-Za-z0-9+/=]+([[:space:]].*)?$ ]] || return 1
    tmp="$(mktemp)"
    printf '%s\n' "$key" > "$tmp"
    ssh-keygen -lf "$tmp" >/dev/null 2>&1
    local result=$?
    rm -f "$tmp"
    return "$result"
}

cleanup_generated_private_key() {
    if [[ -n "${GENERATED_PRIVATE_KEY:-}" ]]; then
        rm -f -- "$GENERATED_PRIVATE_KEY" "${GENERATED_PRIVATE_KEY}.pub"
        GENERATED_PRIVATE_KEY=""
    fi
    if [[ "${GENERATED_KEY_CONFIRMED:-0}" != "1" \
        && -n "${GENERATED_PUBLIC_KEY_LINE:-}" \
        && -f "${TARGET_AUTH_KEYS:-}" ]]; then
        local temp_keys
        temp_keys="$(mktemp)"
        awk -v generated_key="$GENERATED_PUBLIC_KEY_LINE" '$0 != generated_key' \
            "$TARGET_AUTH_KEYS" > "$temp_keys"
        cat "$temp_keys" > "$TARGET_AUTH_KEYS"
        rm -f "$temp_keys"
        fix_authorized_keys_permissions
    fi
    GENERATED_PUBLIC_KEY_LINE=""
}


show_generated_private_key() {
    local key_file="$1"
    ui_subtitle "SSH 私钥（敏感信息）"
    printf '  %s请完整保存以下内容，不要发送给任何人：%s\n\n' "$C_YELLOW" "$C_RESET"
    printf '%s' "$C_RED"
    cat "$key_file"
    printf '%s\n' "$C_RESET"
    printf '  %s本地保存后执行： chmod 600 ~/.ssh/vps-tool-%s%s\n' \
        "$C_DIM" "$TARGET_USER" "$C_RESET"
}


generate_authorized_key() {
    local current_port="${1:-22}" validation_mode="${2:-immediate}"
    local key_name key_file group server_ip public_key old_umask
    local transfer_user transfer_home
    key_name="vps-tool-${TARGET_USER}-$(beijing_compact)"
    transfer_user="$TARGET_USER"
    transfer_home="$TARGET_HOME"
    if [[ "$validation_mode" == "deferred" && "$TARGET_USER" == "root" \
        && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
        && id "$SUDO_USER" >/dev/null 2>&1; then
        transfer_user="$SUDO_USER"
        transfer_home="$(getent passwd "$transfer_user" | cut -d: -f6)"
    fi
    mkdir -p "${transfer_home}/.ssh"
    group="$(id -gn "$transfer_user")"
    chown "$transfer_user:$group" "${transfer_home}/.ssh"
    chmod 700 "${transfer_home}/.ssh"
    key_file="${transfer_home}/.ssh/.${key_name}"
    server_ip="$(awk '{print $3}' <<< "${SSH_CONNECTION:-}")"
    server_ip="${server_ip:-服务器IP}"
    if [[ "$server_ip" == *:* && "$server_ip" != \[*\] ]]; then
        server_ip="[${server_ip}]"
    fi

    old_umask="$(umask)"
    umask 077
    if ! ssh-keygen -q -t ed25519 -a 100 -N '' \
        -C "vps-tool-${TARGET_USER}@$(hostname)-$(beijing_date '+%Y-%m-%d')" \
        -f "$key_file"; then
        umask "$old_umask"
        log_error "SSH 密钥生成失败"
        return 1
    fi
    umask "$old_umask"
    chown "$transfer_user:$group" "$key_file" "${key_file}.pub"
    chmod 600 "$key_file"
    chmod 644 "${key_file}.pub"
    GENERATED_PRIVATE_KEY="$key_file"

    public_key="$(cat "${key_file}.pub")"
    validate_public_key_line "$public_key" \
        || { cleanup_generated_private_key; log_error "自动生成的公钥检查失败"; return 1; }
    GENERATED_PUBLIC_KEY_LINE="$public_key"
    GENERATED_KEY_CONFIRMED=0
    printf '%s\n' "$public_key" >> "$TARGET_AUTH_KEYS"
    fix_authorized_keys_permissions
    log_success "已自动生成 Ed25519 密钥，并写入 authorized_keys"

    ui_subtitle "密钥下载"
    ui_kv "临时私钥" "$key_file"
    printf '\n  %s推荐在本地电脑新开终端下载：%s\n' "$C_BOLD" "$C_RESET"
    printf '  %sscp -P %s %s@%s:%s ~/.ssh/vps-tool-%s%s\n' \
        "$C_CYAN" "$current_port" "$transfer_user" "$server_ip" "$key_file" "$TARGET_USER" "$C_RESET"
    printf '  chmod 600 ~/.ssh/vps-tool-%s\n\n' "$TARGET_USER"

    if confirm "是否在当前终端显示私钥" "Y"; then
        show_generated_private_key "$key_file"
    fi

    while true; do
        if [[ "$validation_mode" == "deferred" ]]; then
            printf '\n%sroot 登录尚未启用，请先下载并妥善保存私钥；稍后会统一确认登录。%s\n' \
                "$C_YELLOW" "$C_RESET"
            if confirm "是否已经下载并保存私钥" "Y"; then
                log_success "私钥将在 root 登录确认成功后从服务器删除"
                return 0
            fi
        else
            printf '\n%s请在本地使用新密钥确认当前 SSH 端口可以登录：%s\n' "$C_YELLOW" "$C_RESET"
            printf '  ssh -i ~/.ssh/vps-tool-%s -p %s %s@%s\n' \
                "$TARGET_USER" "$current_port" "$TARGET_USER" "$server_ip"
            if confirm "是否已经下载私钥并成功登录" "Y"; then
                GENERATED_KEY_CONFIRMED=1
                cleanup_generated_private_key
                log_success "服务器端临时私钥已删除，仅保留公钥"
                return 0
            fi
        fi
        if confirm "是否取消本次密钥配置" "Y"; then
            cleanup_generated_private_key
            log_warn "已删除服务器端临时私钥和新增公钥"
            return 1
        fi
        if confirm "是否重新显示私钥" "Y"; then
            show_generated_private_key "$key_file"
        fi
    done
}


ensure_authorized_key() {
    local target_user="$1" current_port="${2:-22}" validation_mode="${3:-immediate}" key
    resolve_target_user "$target_user"
    fix_authorized_keys_permissions
    if has_valid_authorized_key; then
        log_success "检测到 ${TARGET_USER} 的 authorized_keys"
        ssh-keygen -lf "$TARGET_AUTH_KEYS" 2>/dev/null | sed 's/^/    /' || true
        return 0
    fi

    log_warn "${TARGET_USER} 尚未配置有效 SSH 公钥"
    if confirm "是否自动生成 Ed25519 密钥" "Y"; then
        generate_authorized_key "$current_port" "$validation_mode"
        return $?
    fi
    if ! confirm "是否粘贴已有 SSH 公钥" "Y"; then
        log_warn "已取消 SSH 密钥配置"
        return 1
    fi

    printf '%s请粘贴一整行 SSH 公钥（推荐 ssh-ed25519）：%s\n' "$C_CYAN" "$C_RESET"
    read -r key
    validate_public_key_line "$key" \
        || { log_error "SSH 公钥格式无效，已停止配置"; return 1; }
    printf '%s\n' "$key" >> "$TARGET_AUTH_KEYS"
    fix_authorized_keys_permissions
    log_success "SSH 公钥已写入 ${TARGET_AUTH_KEYS}"
}
