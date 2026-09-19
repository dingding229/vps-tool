#!/usr/bin/env bash
set -u
STATE_FILE="/run/vps-tool-ssh-rollback.env"
LOCK_FILE="/run/lock/vps-tool-ssh-rollback.lock"
LOG_FILE="/var/log/vps-tool/install.log"
APP_TIMEZONE="Asia/Shanghai"
export TZ="$APP_TIMEZONE"
beijing_now() { TZ="$APP_TIMEZONE" date '+%Y-%m-%d %H:%M:%S'; }

exec 8>"$LOCK_FILE"
flock -n 8 || exit 0
[[ -r "$STATE_FILE" ]] || exit 0
# shellcheck disable=SC1090
source "$STATE_FILE"
printf '[%s] [ROLLBACK] 正在恢复 SSH 配置\n' "$(beijing_now)" >> "$LOG_FILE"
if [[ "$DROPIN_EXISTED" == "1" && -f "$BACKUP_FILE" ]]; then
    cp -a "$BACKUP_FILE" "$DROPIN_FILE"
else
    rm -f "$DROPIN_FILE"
fi
if /usr/sbin/sshd -t >> "$LOG_FILE" 2>&1; then
    systemctl reload "$SSH_SERVICE" >> "$LOG_FILE" 2>&1
else
    printf '[%s] [ROLLBACK] 恢复后的 SSH 配置检查失败\n' "$(beijing_now)" >> "$LOG_FILE"
    exit 1
fi
case "$FIREWALL_KIND" in
    ufw) ufw --force delete allow "${NEW_PORT}/tcp" >/dev/null 2>&1 || true ;;
    firewalld)
        firewall-cmd --permanent --remove-port="${NEW_PORT}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ;;
esac
rm -f "$STATE_FILE"
printf '[%s] [ROLLBACK] SSH 配置已恢复\n' "$(beijing_now)" >> "$LOG_FILE"
