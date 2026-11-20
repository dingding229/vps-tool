#!/usr/bin/env bash

backup_ssh_config_snapshot() {
    local backup_dir="$1" file index=0
    shift
    : > "$backup_dir/paths" || return 1
    for file in "$@"; do
        [[ "$file" == /* ]] || return 1
        # 不修改由符号链接或其他非普通文件管理的 SSH 配置。
        if [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
            printf '不支持自动修改 SSH 配置路径：%s\n' "$file" >&2
            return 1
        fi
        if [[ -f "$file" ]]; then
            cp -a -- "$file" "$backup_dir/$index" || return 1
        fi
        printf '%s\n' "$file" >> "$backup_dir/paths" || return 1
        index=$((index + 1))
    done
}

restore_ssh_config_snapshot() {
    local backup_dir="$1" file index=0 result=0
    [[ -s "$backup_dir/paths" ]] || return 1
    while IFS= read -r file; do
        if [[ -f "$backup_dir/$index" ]]; then
            cp -a -- "$backup_dir/$index" "$file" || result=1
        else
            rm -f -- "$file" || result=1
        fi
        index=$((index + 1))
    done < "$backup_dir/paths"
    return "$result"
}

ssh_rollback_main() {
    local state_file="/run/vps-tool-ssh-rollback.env" lock_file="/run/lock/vps-tool-ssh-rollback.lock"
    local log_file="/var/log/vps-tool/install.log" TZ="Asia/Shanghai"
    export TZ
    exec 8>"$lock_file" || return 1
    flock -x 8 || return 1
    [[ -r "$state_file" ]] || return 0
    # shellcheck disable=SC1090
    source "$state_file"
    printf '[%s] [ROLLBACK] 正在恢复 SSH 配置\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$log_file"
    if [[ -n "${SSH_CONFIG_BACKUP_DIR:-}" ]]; then
        restore_ssh_config_snapshot "$SSH_CONFIG_BACKUP_DIR" >> "$log_file" 2>&1 || return 1
    elif [[ "$DROPIN_EXISTED" == "1" && -f "$BACKUP_FILE" ]]; then
        # 兼容旧版本已写入的回滚状态。
        cp -a -- "$BACKUP_FILE" "$DROPIN_FILE" || return 1
    else
        rm -f -- "$DROPIN_FILE" || return 1
    fi
    if ! /usr/sbin/sshd -t >> "$log_file" 2>&1 \
        || ! systemctl reload "$SSH_SERVICE" >> "$log_file" 2>&1; then
        printf '[%s] [ROLLBACK] 恢复后的 SSH 配置检查或重载失败\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$log_file"
        return 1
    fi
    case "$FIREWALL_KIND" in
        ufw) ufw --force delete allow "${NEW_PORT}/tcp" >/dev/null 2>&1 || true ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${NEW_PORT}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
    esac
    rm -f -- "$state_file"
    printf '[%s] [ROLLBACK] SSH 配置已恢复\n' "$(date '+%Y-%m-%d %H:%M:%S')" >> "$log_file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -u
    ssh_rollback_main "$@"
fi
