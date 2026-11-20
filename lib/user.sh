#!/usr/bin/env bash

TARGET_USER="root"
TARGET_HOME="/root"
TARGET_AUTH_KEYS="/root/.ssh/authorized_keys"
GENERATED_PRIVATE_KEY=""
GENERATED_PUBLIC_KEY_LINE=""
GENERATED_KEY_CONFIRMED=0
GENERATED_KEY_DIR=""
GENERATED_KEYS_STATE=""

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
    if [[ -L "${TARGET_HOME}/.ssh" || -L "$TARGET_AUTH_KEYS" \
        || ( -e "$TARGET_AUTH_KEYS" && ! -f "$TARGET_AUTH_KEYS" ) ]]; then
        log_error "公钥文件或其目录使用了不支持的路径，未修改 ${TARGET_AUTH_KEYS}"
        return 1
    fi
    group="$(id -gn "$TARGET_USER")" || return 1
    mkdir -p "${TARGET_HOME}/.ssh" && touch "$TARGET_AUTH_KEYS" \
        && chown "$TARGET_USER:$group" "${TARGET_HOME}/.ssh" "$TARGET_AUTH_KEYS" \
        && chmod 700 "${TARGET_HOME}/.ssh" || return 1
    chmod 600 "$TARGET_AUTH_KEYS"
}

has_valid_authorized_key() {
    [[ -s "$TARGET_AUTH_KEYS" ]] || return 1
    ssh-keygen -lf "$TARGET_AUTH_KEYS" >/dev/null 2>&1
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

replace_authorized_keys() {
    local replacement="$1" expected="$2" temp_keys group
    [[ -f "$TARGET_AUTH_KEYS" && ! -L "$TARGET_AUTH_KEYS" && ! -L "${TARGET_HOME}/.ssh" ]] || return 1
    group="$(id -gn "$TARGET_USER")" || return 1
    temp_keys="$(mktemp "${TARGET_AUTH_KEYS}.vps-tool.XXXXXX")" || return 1
    if cat "$replacement" > "$temp_keys" && chown "$TARGET_USER:$group" "$temp_keys" \
        && chmod 600 "$temp_keys" && cmp -s "$expected" "$TARGET_AUTH_KEYS" \
        && mv -f -- "$temp_keys" "$TARGET_AUTH_KEYS"; then
        return 0
    fi
    rm -f -- "$temp_keys"
    return 1
}

cleanup_generated_private_key() {
    local state="$GENERATED_KEYS_STATE"
    if [[ -n "${GENERATED_PRIVATE_KEY:-}" ]]; then
        rm -f -- "$GENERATED_PRIVATE_KEY" "${GENERATED_PRIVATE_KEY}.pub"
        GENERATED_PRIVATE_KEY=""
    fi
    if [[ -n "$GENERATED_KEY_DIR" ]]; then
        rmdir -- "$GENERATED_KEY_DIR" 2>/dev/null || true
        GENERATED_KEY_DIR=""
    fi
    if [[ -n "$state" ]]; then
        if [[ "$GENERATED_KEY_CONFIRMED" != "1" && -n "$GENERATED_PUBLIC_KEY_LINE" \
            && -f "$TARGET_AUTH_KEYS" && ! -L "$TARGET_AUTH_KEYS" ]]; then
            if cmp -s "$state/staged" "$TARGET_AUTH_KEYS"; then
                replace_authorized_keys "$state/original" "$state/staged" \
                    || log_warn "无法恢复原公钥文件，请检查 ${TARGET_AUTH_KEYS}"
            elif grep -qxF -- "$GENERATED_PUBLIC_KEY_LINE" "$TARGET_AUTH_KEYS"; then
                # 保留验证期间其他程序写入的内容，只撤回本工具刚添加的公钥。
                if ! { cp -- "$TARGET_AUTH_KEYS" "$state/current" \
                    && awk -v key="$GENERATED_PUBLIC_KEY_LINE" '$0 != key' "$state/current" > "$state/cleaned" \
                    && replace_authorized_keys "$state/cleaned" "$state/current"; }; then
                    log_warn "无法移除未确认的新公钥，请检查 ${TARGET_AUTH_KEYS}"
                fi
            fi
        fi
        rm -f -- "$state/original" "$state/staged" "$state/current" "$state/cleaned" "$state/rotated"
        rmdir -- "$state" 2>/dev/null || true
        GENERATED_KEYS_STATE=""
    fi
    GENERATED_PUBLIC_KEY_LINE=""
}

stage_generated_authorized_key() {
    local state
    GENERATED_KEY_CONFIRMED=0
    GENERATED_KEYS_STATE="$(mktemp -d)" || return 1
    state="$GENERATED_KEYS_STATE"
    cp -- "$TARGET_AUTH_KEYS" "$state/original" \
        && awk '{print}' "$state/original" > "$state/staged" \
        && printf '%s\n' "$GENERATED_PUBLIC_KEY_LINE" >> "$state/staged" \
        && replace_authorized_keys "$state/staged" "$state/original"
}

commit_authorized_key_rotation() {
    local state="$GENERATED_KEYS_STATE"
    awk '/^[[:space:]]*(#|$)/ {print}' "$state/original" > "$state/rotated" \
        && printf '%s\n' "$GENERATED_PUBLIC_KEY_LINE" >> "$state/rotated" || return 1
    # 先标记新密钥已验证，避免在原子替换后收到信号时删除唯一可用的公钥。
    GENERATED_KEY_CONFIRMED=1
    if ! replace_authorized_keys "$state/rotated" "$state/staged"; then
        GENERATED_KEY_CONFIRMED=0
        return 1
    fi
}

show_generated_private_key() {
    local key_file="$1" local_name="$2"
    ui_subtitle "SSH 私钥（敏感信息）"
    printf '  %s请完整保存以下内容，不要发送给任何人：%s\n\n' "$C_YELLOW" "$C_RESET"
    printf '%s' "$C_RED"
    cat "$key_file"
    printf '%s\n' "$C_RESET"
    printf '  %s本地保存后执行： chmod 600 ~/.ssh/%s%s\n' \
        "$C_DIM" "$local_name" "$C_RESET"
}


generate_authorized_key() {
    local current_port="${1:-22}" validation_mode="${2:-immediate}"
    local key_name key_file group server_ip scp_host public_key
    local transfer_user transfer_home local_name verification_prompt
    key_name="vps-tool-${TARGET_USER}-$(beijing_compact)"
    transfer_user="$TARGET_USER"
    transfer_home="$TARGET_HOME"
    if [[ "$validation_mode" == "deferred" && "$TARGET_USER" == "root" \
        && -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
        && id "$SUDO_USER" >/dev/null 2>&1; then
        transfer_user="$SUDO_USER"
        transfer_home="$(getent passwd "$transfer_user" | cut -d: -f6)"
    fi
    [[ ! -L "${transfer_home}/.ssh" ]] || return 1
    group="$(id -gn "$transfer_user")" || return 1
    mkdir -p "${transfer_home}/.ssh" \
        && chown "$transfer_user:$group" "${transfer_home}/.ssh" \
        && chmod 700 "${transfer_home}/.ssh" || return 1
    GENERATED_KEY_DIR="$(mktemp -d "${transfer_home}/.ssh/.${key_name}.XXXXXX")" || return 1
    key_file="${GENERATED_KEY_DIR}/id_ed25519"
    GENERATED_PRIVATE_KEY="$key_file"
    local_name="${key_name}-${GENERATED_KEY_DIR##*.}"
    server_ip="$(awk '{print $3}' <<< "${SSH_CONNECTION:-}")"
    server_ip="${server_ip:-服务器IP}"
    scp_host="$server_ip"
    [[ "$server_ip" == *:* ]] && scp_host="[${server_ip}]"

    if ! (umask 077; ssh-keygen -q -t ed25519 -a 100 -N '' \
        -C "vps-tool-${TARGET_USER}@$(hostname)-$(beijing_date '+%Y-%m-%d')" \
        -f "$key_file"); then
        cleanup_generated_private_key
        log_error "SSH 密钥生成失败"
        return 1
    fi
    if ! chown "$transfer_user:$group" "$key_file" "${key_file}.pub" "$GENERATED_KEY_DIR"; then
        cleanup_generated_private_key
        log_error "无法设置临时密钥的所有者"
        return 1
    fi

    if ! public_key="$(cat "${key_file}.pub")" || ! validate_public_key_line "$public_key"; then
        cleanup_generated_private_key
        log_error "自动生成的公钥检查失败"
        return 1
    fi
    GENERATED_PUBLIC_KEY_LINE="$public_key"
    if ! stage_generated_authorized_key; then
        cleanup_generated_private_key
        log_error "无法添加新公钥，未移除现有公钥"
        return 1
    fi
    log_success "已自动生成 Ed25519 密钥，并写入 authorized_keys"

    ui_subtitle "密钥下载"
    ui_kv "临时私钥" "$key_file"
    printf '\n  %s推荐在本地电脑新开终端下载：%s\n' "$C_BOLD" "$C_RESET"
    printf '  %sscp -P %s %q ~/.ssh/%s%s\n' \
        "$C_CYAN" "$current_port" "${transfer_user}@${scp_host}:${key_file}" "$local_name" "$C_RESET"
    printf '  chmod 600 ~/.ssh/%s\n\n' "$local_name"

    if confirm "是否在当前终端显示私钥" "Y"; then
        show_generated_private_key "$key_file" "$local_name"
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
            printf '\n%s请保留当前连接，在本地新终端使用新私钥登录：%s\n' "$C_YELLOW" "$C_RESET"
            printf '  ssh -F /dev/null -o IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey -i ~/.ssh/%s -p %s %s@%s\n' \
                "$local_name" "$current_port" "$TARGET_USER" "$server_ip"
            verification_prompt="是否已保存新私钥并使用它成功登录"
            if [[ "$validation_mode" == "rotate" ]]; then
                verification_prompt+="，确认后移除旧公钥"
            fi
            if confirm "$verification_prompt" "Y"; then
                if [[ "$validation_mode" == "rotate" ]]; then
                    if ! commit_authorized_key_rotation; then
                        cleanup_generated_private_key
                        log_error "公钥文件已变更或无法写入，未执行旧公钥替换，请检查后重试"
                        return 1
                    fi
                    log_success "已移除旧公钥，仅保留新公钥"
                fi
                GENERATED_KEY_CONFIRMED=1
                cleanup_generated_private_key
                log_success "服务器端临时私钥已删除，仅保留公钥"
                return 0
            fi
        fi
        if confirm "是否取消本次密钥配置" "Y" || [[ "$?" == "2" ]]; then
            cleanup_generated_private_key
            log_warn "已取消密钥配置，未移除现有公钥"
            return 1
        fi
        if confirm "是否重新显示私钥" "Y"; then
            show_generated_private_key "$key_file" "$local_name"
        fi
    done
}


ensure_authorized_key() {
    local target_user="$1" current_port="${2:-22}" validation_mode="${3:-immediate}" key
    resolve_target_user "$target_user" || return 1
    fix_authorized_keys_permissions || return 1
    if has_valid_authorized_key; then
        log_success "检测到 ${TARGET_USER} 的 authorized_keys"
        ssh-keygen -lf "$TARGET_AUTH_KEYS" 2>/dev/null | sed 's/^/    /' || true
        [[ "$validation_mode" == "immediate" ]] || return 0
        if confirm "是否保留现有 SSH 密钥（选 N 则生成新密钥替换）" "Y"; then
            return 0
        elif [[ "$?" == "2" ]]; then
            return 1
        fi

        ui_subtitle "SSH 密钥换新"
        ui_kv "替换范围" "$TARGET_AUTH_KEYS"
        log_warn "旧公钥及其授权选项将在新密钥登录确认后移除，其他授权来源不变"
        log_info "密钥换新按当前 SSH 端口单独确认，不随之后的端口配置取消"
        generate_authorized_key "$current_port" rotate
        return $?
    fi

    log_warn "${TARGET_USER} 尚未配置有效 SSH 公钥"
    if confirm "是否自动生成 Ed25519 密钥" "Y"; then
        generate_authorized_key "$current_port" "$validation_mode"
        return $?
    elif [[ "$?" == "2" ]]; then
        return 1
    fi
    if ! confirm "是否粘贴已有 SSH 公钥" "Y"; then
        log_warn "已取消 SSH 密钥配置"
        return 1
    fi

    printf '%s请粘贴一整行 SSH 公钥（推荐 ssh-ed25519）：%s\n' "$C_CYAN" "$C_RESET"
    read -r key || return 1
    validate_public_key_line "$key" \
        || { log_error "SSH 公钥格式无效，已停止配置"; return 1; }
    printf '%s\n' "$key" >> "$TARGET_AUTH_KEYS" || return 1
    fix_authorized_keys_permissions || return 1
    log_success "SSH 公钥已写入 ${TARGET_AUTH_KEYS}"
}
