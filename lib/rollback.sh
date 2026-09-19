#!/usr/bin/env bash

SSH_ROLLBACK_LOCK="/run/lock/vps-tool-ssh-rollback.lock"

install_rollback_helper() {
    mkdir -p /usr/local/lib/vps-tool
    install -m 700 "${SCRIPT_DIR}/scripts/ssh-rollback-action.sh" /usr/local/lib/vps-tool/ssh-rollback-action.sh
}

schedule_ssh_rollback() {
    local backup_file="$1" existed="$2" new_port="$3" firewall_kind="$4" service_name="$5" timeout="$6"
    install_rollback_helper
    cat > "$SSH_ROLLBACK_STATE" <<STATE
DROPIN_FILE=$(printf '%q' "$SSH_DROPIN_FILE")
BACKUP_FILE=$(printf '%q' "$backup_file")
DROPIN_EXISTED=$(printf '%q' "$existed")
NEW_PORT=$(printf '%q' "$new_port")
FIREWALL_KIND=$(printf '%q' "$firewall_kind")
SSH_SERVICE=$(printf '%q' "$service_name")
STATE
    chmod 600 "$SSH_ROLLBACK_STATE"
    systemctl stop "${SSH_ROLLBACK_UNIT}.timer" "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    systemctl reset-failed "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
    systemd-run --unit="$SSH_ROLLBACK_UNIT" --on-active="${timeout}s" \
        /usr/local/lib/vps-tool/ssh-rollback-action.sh >/dev/null 2>&1
    log_warn "已设置 ${timeout} 秒 SSH 自动回滚保护"
}

cancel_ssh_rollback() {
    local expected_port="${1:-}"
    exec 8>"$SSH_ROLLBACK_LOCK"
    flock -x 8
    systemctl stop "${SSH_ROLLBACK_UNIT}.timer" >/dev/null 2>&1 || true

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

    systemctl stop "${SSH_ROLLBACK_UNIT}.service" >/dev/null 2>&1 || true
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
