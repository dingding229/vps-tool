#!/usr/bin/env bash

TARGET_USER="root"
TARGET_HOME="/root"
TARGET_AUTH_KEYS="/root/.ssh/authorized_keys"

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

ensure_authorized_key() {
    resolve_target_user "$1"
    fix_authorized_keys_permissions
    if has_valid_authorized_key; then
        log_success "检测到 ${TARGET_USER} 的 authorized_keys"
        ssh-keygen -lf "$TARGET_AUTH_KEYS" 2>/dev/null | sed 's/^/    /' || true
        return 0
    fi

    log_warn "${TARGET_USER} 尚未配置有效 SSH 公钥"
    printf '%s请粘贴一整行 SSH 公钥（推荐 ssh-ed25519）：%s\n' "$C_CYAN" "$C_RESET"
    local key
    read -r key
    validate_public_key_line "$key" || die "SSH 公钥格式无效，已停止配置"
    printf '%s\n' "$key" >> "$TARGET_AUTH_KEYS"
    fix_authorized_keys_permissions
    log_success "SSH 公钥已写入 ${TARGET_AUTH_KEYS}"
}
