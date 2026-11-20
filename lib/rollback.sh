#!/usr/bin/env bash

SSH_ROLLBACK_LOCK="/run/lock/vps-tool-ssh-rollback.lock"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/scripts/ssh-rollback-action.sh"

SSH_PENDING_BACKUP=""
SSH_PENDING_PORT=""
SSH_PENDING_FIREWALL="none"
SSH_PENDING_RELOAD=0

create_ssh_config_snapshot() {
    local backup_dir
    backup_dir="$(mktemp -d "${APP_BACKUP_DIR}/ssh-$(beijing_compact).XXXXXX")" || return 1
    backup_ssh_config_snapshot "$backup_dir" "$@" || return 1
    printf '%s' "$backup_dir"
}

clear_pending_ssh_config() {
    SSH_PENDING_BACKUP=""
    SSH_PENDING_PORT=""
    SSH_PENDING_FIREWALL="none"
    SSH_PENDING_RELOAD=0
}

cleanup_pending_ssh_config() {
    [[ -n "$SSH_PENDING_BACKUP" ]] || return 0
    if ! restore_ssh_config_snapshot "$SSH_PENDING_BACKUP"; then
        log_error "无法完整恢复 SSH 配置，请从 ${SSH_PENDING_BACKUP} 检查备份"
        return 1
    fi
    if (( SSH_PENDING_RELOAD == 1 )); then
        if ! sshd -t || ! systemctl reload "$SSH_SERVICE"; then
            log_error "已恢复原 SSH 配置，但服务重载失败，请通过 VPS 控制台检查"
            clear_pending_ssh_config
            return 1
        fi
    fi
    if [[ "$SSH_PENDING_FIREWALL" == ufw || "$SSH_PENDING_FIREWALL" == firewalld ]]; then
        firewall_remove_ssh_port "$SSH_PENDING_PORT"
    fi
    clear_pending_ssh_config
}

install_rollback_helper() {
    mkdir -p /usr/local/lib/vps-tool || return 1
    install -m 700 "${SCRIPT_DIR}/scripts/ssh-rollback-action.sh" /usr/local/lib/vps-tool/ssh-rollback-action.sh
}

schedule_ssh_rollback() {
    local backup_dir="$1" new_port="$2" firewall_kind="$3" service_name="$4" timeout="$5"
    install_rollback_helper || return 1
    (umask 077; cat > "$SSH_ROLLBACK_STATE") <<STATE || return 1
SSH_CONFIG_BACKUP_DIR=$(printf '%q' "$backup_dir")
NEW_PORT=$(printf '%q' "$new_port")
FIREWALL_KIND=$(printf '%q' "$firewall_kind")
SSH_SERVICE=$(printf '%q' "$service_name")
STATE
    systemctl stop "${SSH_ROLLBACK_UNIT}.timer" "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    if ! systemd-run --unit="$SSH_ROLLBACK_UNIT" --on-active="${timeout}s" \
        /usr/local/lib/vps-tool/ssh-rollback-action.sh >/dev/null 2>&1; then
        rm -f -- "$SSH_ROLLBACK_STATE"
        return 1
    fi
    log_warn "已设置 ${timeout} 秒 SSH 自动回滚保护"
}

cancel_ssh_rollback() {
    local expected_port="${1:-}"
    exec 8>"$SSH_ROLLBACK_LOCK"
    flock -x 8

    if [[ ! -f "$SSH_ROLLBACK_STATE" ]]; then
        flock -u 8
        log_error "回滚状态已不存在，自动回滚可能已经执行"
        return 1
    fi
    if [[ -n "$expected_port" ]]; then
        local effective_port
        effective_port="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')"
        if [[ "$effective_port" != "$expected_port" ]] \
            || ! ss -lntH 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${expected_port}$"; then
            flock -u 8
            log_error "新 SSH 端口未保持生效，不会取消自动回滚"
            return 1
        fi
    fi

    systemctl stop "${SSH_ROLLBACK_UNIT}.timer" "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    rm -f "$SSH_ROLLBACK_STATE"
    flock -u 8
    log_success "已安全取消 SSH 自动回滚任务"
}

run_ssh_rollback_now() {
    if [[ ! -f "$SSH_ROLLBACK_STATE" ]]; then
        log_warn "没有待处理的 SSH 回滚任务"
        return 1
    fi
    /usr/local/lib/vps-tool/ssh-rollback-action.sh
}
