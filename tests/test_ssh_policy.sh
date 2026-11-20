#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
if ! command -v sshd >/dev/null || ! command -v ssh-keygen >/dev/null; then
    printf 'sshd or ssh-keygen not installed; skipping SSH policy integration tests\n'
    exit 0
fi
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh
source lib/rollback.sh
source lib/ssh.sh
source lib/root-login.sh

temp_dir="$(mktemp -d)"
cleanup() {
    python3 - "$temp_dir" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT
ssh-keygen -q -t ed25519 -N '' -f "$temp_dir/host_key"

setup_config() {
    fixture="$temp_dir/$1"
    APP_BACKUP_DIR="$fixture/backups"
    APP_STATE_DIR="$fixture/state"
    SSHD_MAIN_CONFIG="$fixture/sshd_config"
    SSH_DROPIN_FILE="$fixture/vps-tool-ssh.conf"
    SSH_LEGACY_DROPIN_FILE="$fixture/conf.d/00-vps-tool.conf"
    ROOT_SSH_DROPIN_FILE="$fixture/conf.d/00-00-vps-tool-root-access.conf"
    SSH_ROLLBACK_STATE="$fixture/rollback.env"
    SSH_ROLLBACK_LOCK="$fixture/rollback.lock"
    TEMP_PASSWORD_CONFIG="$fixture/conf.d/00-temp-password.conf"
    mkdir -p "$APP_BACKUP_DIR" "$APP_STATE_DIR" "$fixture/conf.d"
    printf 'HostKey %s\n' "$temp_dir/host_key" > "$SSHD_MAIN_CONFIG"
}

# 仅执行 sshd 的配置检查模式；服务、连接和自动回滚定时器由测试替代。
simulate_older_parser=0
sshd() {
    if [[ "$1" == '-t' && "$simulate_older_parser" == '1' && -f "$SSH_DROPIN_FILE" && -f "$TEMP_PASSWORD_CONFIG" ]]; then
        printf '%s line 4: "any" must appear alone in AuthenticationMethods\n' "$TEMP_PASSWORD_CONFIG" >&2
        return 255
    fi
    command sshd -f "$SSHD_MAIN_CONFIG" "$@"
}
ss() { printf 'LISTEN 0 128 0.0.0.0:6900 0.0.0.0:*\n'; }
flock() { :; }
sleep() { :; }
install_rollback_helper() { :; }
fail_timer=0
systemd-run() { (( fail_timer == 0 )); }
systemctl() {
    if [[ "$1" == is-active ]]; then printf 'active\n'; fi
    if [[ "$1" == reload ]]; then printf '%s\n' "$*" >> "$fixture/reloads"; fi
    return 0
}
prompt_value() {
    case "$1" in
        '配置密钥登录的用户') printf 'root' ;;
        '新的 SSH 端口') printf '6900' ;;
        *) return 1 ;;
    esac
}
ensure_authorized_key() { :; }
test_login_ok=1
disable_temp_password_ok=0
confirm() {
    case "$1" in
        '确认继续') return 0 ;;
        '是否已使用新端口和密钥登录成功') (( test_login_ok == 1 )) ;;
        '是否备份并停用此临时密码配置') (( disable_temp_password_ok == 1 )) ;;
        *) return 1 ;;
    esac
}
run_ssh_rollback_now() {
    # 读取定时回滚收到的实际快照路径，避免操作测试机自己的 SSH 服务。
    local SSH_CONFIG_BACKUP_DIR=""
    source "$SSH_ROLLBACK_STATE"
    restore_ssh_config_snapshot "$SSH_CONFIG_BACKUP_DIR"
}

setup_config no-include
printf 'Port 6900\nPasswordAuthentication yes\n' >> "$SSHD_MAIN_CONFIG"
if verify_effective_ssh_config 6900 root > "$fixture/before" 2>&1; then
    printf 'FAIL: did not reproduce the original password authentication error\n'
    exit 1
fi
grep -Fq 'PasswordAuthentication 未生效（用户 root，实际：yes，期望：no）' "$fixture/before"
configure_ssh_interactive > "$fixture/result" 2>&1
[[ "$(head -n 1 "$SSHD_MAIN_CONFIG")" == "Include $SSH_DROPIN_FILE" ]]
verify_effective_ssh_config 6900 root prohibit-password
printf 'SSH auth precedence when the main config does not include a drop-in: OK\n'

prepare_legacy_config() {
    printf 'Include %s\nInclude %s\n' "$SSH_LEGACY_DROPIN_FILE" "$fixture/conf.d/*.conf" >> "$SSHD_MAIN_CONFIG"
    printf 'PasswordAuthentication yes\n' > "$fixture/cloud.conf"
    # 云镜像的全局规则早于旧版 drop-in；同一个旧文件被引用两次。
    { printf 'Include %s\n' "$fixture/cloud.conf"; cat "$SSHD_MAIN_CONFIG"; } > "$fixture/main"
    cp "$fixture/main" "$SSHD_MAIN_CONFIG"
    SSH_DROPIN_FILE="$SSH_LEGACY_DROPIN_FILE" write_ssh_dropin 6900 prohibit-password
    write_root_access_dropin password
    ensure_root_access_include_first
    printf 'MODE=password\n' > "$APP_STATE_DIR/root-login.conf"
    cp "$SSHD_MAIN_CONFIG" "$fixture/main-before"
    cp "$SSH_LEGACY_DROPIN_FILE" "$fixture/legacy-before"
    cp "$ROOT_SSH_DROPIN_FILE" "$fixture/root-before"
}

setup_config migration
prepare_legacy_config
[[ "$(sshd -T -C 'user=root,host=localhost,addr=127.0.0.1' | grep -cFx 'port 6900')" == '2' ]]
configure_ssh_interactive > "$fixture/result" 2>&1
grep -Fq '移除原 VPS Tool root 专用规则' "$fixture/result"
[[ ! -e "$SSH_LEGACY_DROPIN_FILE" && ! -e "$ROOT_SSH_DROPIN_FILE" && ! -e "$APP_STATE_DIR/root-login.conf" ]]
[[ "$(sshd -T | grep -cFx 'port 6900')" == '1' ]]
verify_effective_ssh_config 6900 root prohibit-password
grep -Fxq 'PasswordAuthentication yes' "$fixture/cloud.conf"
printf 'SSH config migration retains the existing port and resolves the managed root conflict: OK\n'

assert_restored() {
    cmp "$fixture/main-before" "$SSHD_MAIN_CONFIG"
    cmp "$fixture/legacy-before" "$SSH_LEGACY_DROPIN_FILE"
    cmp "$fixture/root-before" "$ROOT_SSH_DROPIN_FILE"
    [[ ! -e "$SSH_DROPIN_FILE" ]]
    grep -Fxq 'MODE=password' "$APP_STATE_DIR/root-login.conf"
}

setup_config timer-failure
prepare_legacy_config
fail_timer=1
if configure_ssh_interactive > "$fixture/result" 2>&1; then
    printf 'FAIL: a failed rollback timer must prevent applying the policy\n'
    exit 1
fi
grep -Fq '无法创建 SSH 自动回滚任务' "$fixture/result"
[[ ! -e "$fixture/reloads" && ! -e "$SSH_ROLLBACK_STATE" ]]
assert_restored
fail_timer=0
printf 'SSH rollback timer failure restores all configuration without reloading: OK\n'

setup_config login-cancelled
prepare_legacy_config
test_login_ok=0
if configure_ssh_interactive > "$fixture/result" 2>&1; then
    printf 'FAIL: an unconfirmed login must not keep the new policy\n'
    exit 1
fi
[[ -s "$fixture/reloads" ]]
assert_restored
test_login_ok=1
printf 'SSH rollback snapshot restores the main, legacy and root configurations: OK\n'

setup_config third-party-match
cat >> "$SSHD_MAIN_CONFIG" <<'CONF'
Port 6900
Match User root
    PasswordAuthentication yes
    AuthenticationMethods any
CONF
cp "$SSHD_MAIN_CONFIG" "$fixture/main-before"
if configure_ssh_interactive > "$fixture/result" 2>&1; then
    printf 'FAIL: third-party Match must not be bypassed\n'
    exit 1
fi
grep -Fq 'PasswordAuthentication 未生效（用户 root，实际：yes，期望：no）' "$fixture/result"
cmp "$fixture/main-before" "$SSHD_MAIN_CONFIG"
[[ ! -e "$fixture/reloads" && ! -e "$SSH_DROPIN_FILE" ]]
printf 'SSH conflicting third-party Match reports the actual value and rolls back: OK\n'

prepare_temp_password_config() {
    printf 'Port 6900\nInclude %s\n' "$fixture/conf.d/*.conf" >> "$SSHD_MAIN_CONFIG"
    cat > "$TEMP_PASSWORD_CONFIG" <<CONF
# Temporary password access
PermitRootLogin yes
PasswordAuthentication yes
AuthenticationMethods $1
CONF
    cp "$TEMP_PASSWORD_CONFIG" "$fixture/temp-before"
    cp "$SSHD_MAIN_CONFIG" "$fixture/main-before"
}

setup_config already-invalid-any
prepare_temp_password_config 'any publickey'
if sshd -t > "$fixture/before" 2>&1; then
    printf 'FAIL: the invalid AuthenticationMethods fixture passed\n'
    exit 1
fi
grep -Fq '"any" must appear alone in AuthenticationMethods' "$fixture/before"
disable_temp_password_ok=1
if ! configure_ssh_interactive > "$fixture/result" 2>&1; then
    cat "$fixture/result" >&2
    exit 1
fi
grep -Fq '请保留当前连接，重新选择「配置 SSH 安全策略」继续' "$fixture/result"
[[ ! -e "$TEMP_PASSWORD_CONFIG" && ! -e "$SSH_DROPIN_FILE" && ! -e "$fixture/reloads" ]]
cmp "$fixture/main-before" "$SSHD_MAIN_CONFIG"
snapshot_files=("$APP_BACKUP_DIR"/*/0)
[[ "${#snapshot_files[@]}" == 1 ]]
cmp "$fixture/temp-before" "${snapshot_files[0]}"
sshd -t
printf 'Invalid temporary password config can be disabled without reloading or changing the port: OK\n'

setup_config refused-temp-conflict
prepare_temp_password_config any
simulate_older_parser=1
disable_temp_password_ok=0
if configure_ssh_interactive > "$fixture/result" 2>&1; then
    printf 'FAIL: refusing to disable the temp config should keep all original settings\n'
    exit 1
fi
cmp "$fixture/main-before" "$SSHD_MAIN_CONFIG"
cmp "$fixture/temp-before" "$TEMP_PASSWORD_CONFIG"
[[ ! -e "$SSH_DROPIN_FILE" && ! -e "$fixture/reloads" ]]

setup_config declined-new-login
prepare_temp_password_config any
disable_temp_password_ok=1
test_login_ok=0
if configure_ssh_interactive > "$fixture/result" 2>&1; then
    printf 'FAIL: a rollback should restore the disabled temporary password config\n'
    exit 1
fi
grep -Fq '回滚时会恢复' "$fixture/result"
cmp "$fixture/main-before" "$SSHD_MAIN_CONFIG"
cmp "$fixture/temp-before" "$TEMP_PASSWORD_CONFIG"
[[ ! -e "$SSH_DROPIN_FILE" && -s "$fixture/reloads" ]]
printf 'Temporary password config conflict remains reversible until a new login is confirmed: OK\n'

setup_config accepted-temp-conflict
prepare_temp_password_config any
test_login_ok=1
configure_ssh_interactive > "$fixture/result" 2>&1
[[ ! -e "$TEMP_PASSWORD_CONFIG" && ! -e "$SSH_ROLLBACK_STATE" ]]
verify_effective_ssh_config 6900 root prohibit-password

setup_config extra-rules
prepare_temp_password_config any
printf 'AllowUsers root\n' >> "$TEMP_PASSWORD_CONFIG"
cp "$TEMP_PASSWORD_CONFIG" "$fixture/temp-before"
if configure_ssh_interactive > "$fixture/result" 2>&1; then
    printf 'FAIL: a temp file containing additional access rules must not be taken out of service\n'
    exit 1
fi
cmp "$fixture/temp-before" "$TEMP_PASSWORD_CONFIG"
[[ ! -e "$SSH_DROPIN_FILE" && ! -e "$fixture/reloads" ]]
printf 'Temporary config is only disabled when it contains no unrelated SSH settings: OK\n'
