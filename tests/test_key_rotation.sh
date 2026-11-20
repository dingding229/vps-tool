#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
source config/defaults.conf
source lib/common.sh
source lib/user.sh
source lib/ssh.sh

temp_dir="$(mktemp -d)"
cleanup() {
    cleanup_generated_private_key
    python3 - "$temp_dir" <<'PY'
import shutil, sys
shutil.rmtree(sys.argv[1])
PY
}
trap cleanup EXIT

resolve_target_user() {
    TARGET_USER="$(id -un)"
    TARGET_HOME="$temp_dir/home"
    TARGET_AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"
}
resolve_target_user
fix_authorized_keys_permissions
ssh-keygen -q -t ed25519 -N '' -C 'old' -f "$temp_dir/old"
ssh-keygen -q -t ed25519 -N '' -C 'added externally' -f "$temp_dir/extra"
old_key="$(cat "$temp_dir/old.pub")"
# 旧密钥含授权选项，且文件末尾没有换行。
printf '# Keep this comment\n\nfrom="192.0.2.1",command="echo hello" %s' "$old_key" > "$temp_dir/original"
cp "$temp_dir/original" "$TARGET_AUTH_KEYS"

assert_clean() {
    [[ -z "$GENERATED_PRIVATE_KEY" && -z "$GENERATED_KEYS_STATE" ]]
    [[ -z "$(find "$TARGET_HOME/.ssh" -mindepth 1 ! -name authorized_keys -print)" ]]
}

ensure_authorized_key "$TARGET_USER" 6900 <<< '' > "$temp_dir/output" 2>&1
grep -Fq '是否保留现有 SSH 密钥' "$temp_dir/output"
cmp "$temp_dir/original" "$TARGET_AUTH_KEYS"
assert_clean
printf 'SSH key rotation opt-in: OK\n'

if ensure_authorized_key "$TARGET_USER" 6900 <<< $'N\nN\nN\nY' > "$temp_dir/output" 2>&1; then
    printf 'FAIL: cancelled key rotation unexpectedly succeeded\n'
    exit 1
fi
cmp "$temp_dir/original" "$TARGET_AUTH_KEYS"
assert_clean

if ensure_authorized_key "$TARGET_USER" 6900 <<< $'N\nN' > "$temp_dir/output" 2>&1; then
    printf 'FAIL: EOF unexpectedly confirmed key rotation\n'
    exit 1
fi
cmp "$temp_dir/original" "$TARGET_AUTH_KEYS"
assert_clean
printf 'SSH key rotation cancellation and EOF: OK\n'

# 用入口脚本的真实退出处理验证连接中断时的恢复。
exit_status=0
bash -c '
    source ./vps-init.sh --help >/dev/null
    TARGET_USER="$(id -un)"
    TARGET_HOME="$1"
    TARGET_AUTH_KEYS="$TARGET_HOME/.ssh/authorized_keys"
    confirm() {
        case "$1" in
            "是否在当前终端显示私钥") return 1 ;;
            "是否已保存新私钥"*) kill -TERM "$$" ;;
            *) exit 1 ;;
        esac
    }
    generate_authorized_key 6900 rotate
' bash "$TARGET_HOME" > "$temp_dir/output" 2>&1 || exit_status=$?
[[ "$exit_status" == '143' ]]
cmp "$temp_dir/original" "$TARGET_AUTH_KEYS"
assert_clean
printf 'SSH key rotation interruption recovery: OK\n'

# 在最终确认处检查新旧公钥共存，并模拟另一个程序写入公钥文件。
change_during_test=1
confirm_new_login=1
add_restriction_before_stage=0
confirm() {
    case "$1" in
        '是否保留现有 SSH 密钥'*|'是否在当前终端显示私钥') return 1 ;;
        '是否生成新的 Ed25519 密钥')
            if [[ "$add_restriction_before_stage" == "1" ]]; then
                cp "$temp_dir/original" "$TARGET_AUTH_KEYS"
            fi
            return 0
            ;;
        '是否取消本次密钥配置') return 0 ;;
        '是否已保存新私钥并使用它成功登录，确认后移除旧公钥')
            grep -Fq -- "$old_key" "$TARGET_AUTH_KEYS" || exit 1
            grep -Fxq -- "$GENERATED_PUBLIC_KEY_LINE" "$TARGET_AUTH_KEYS" || exit 1
            [[ -s "$GENERATED_PRIVATE_KEY" ]] || exit 1
            if [[ "$change_during_test" == "1" ]]; then
                cat "$temp_dir/extra.pub" >> "$TARGET_AUTH_KEYS"
            fi
            [[ "$confirm_new_login" == "1" ]]
            ;;
        *) printf 'FAIL: unexpected prompt: %s\n' "$1" >&2; exit 1 ;;
    esac
}

if ensure_authorized_key "$TARGET_USER" 6900 > "$temp_dir/output" 2>&1; then
    printf 'FAIL: a concurrent edit was overwritten\n'
    exit 1
fi
{ cat "$temp_dir/original"; printf '\n'; cat "$temp_dir/extra.pub"; } > "$temp_dir/expected"
cmp "$temp_dir/expected" "$TARGET_AUTH_KEYS"
assert_clean
printf 'SSH key rotation preserves concurrent edits: OK\n'

change_during_test=0
ensure_authorized_key "$TARGET_USER" 6900 > "$temp_dir/output" 2>&1
grep -Fq '已移除旧公钥' "$temp_dir/output"
grep -Fq 'IdentitiesOnly=yes -o IdentityAgent=none -o PreferredAuthentications=publickey' "$temp_dir/output"
grep -Fq ' -p 6900 ' "$temp_dir/output"
grep -Fxq '# Keep this comment' "$TARGET_AUTH_KEYS"
[[ "$(grep -Ec '^ssh-ed25519[[:space:]]' "$TARGET_AUTH_KEYS")" == '1' ]]
if grep -Fq -- "$old_key" "$TARGET_AUTH_KEYS" || grep -Fqf "$temp_dir/extra.pub" "$TARGET_AUTH_KEYS"; then
    printf 'FAIL: old key was not removed after confirmation\n'
    exit 1
fi
[[ "$(ssh-keygen -lf "$TARGET_AUTH_KEYS" | wc -l | tr -d ' ')" == '1' ]]
assert_clean
printf 'SSH key rotation after successful verification: OK\n'

# 独立入口只读取端口。任何修改配置或服务的命令都不得执行。
SSH_DROPIN_FILE="$temp_dir/ssh-dropin.conf"
SSHD_MAIN_CONFIG="$temp_dir/sshd_config"
ROOT_SSH_DROPIN_FILE="$temp_dir/root-dropin.conf"
printf 'Port 6900\nAuthenticationMethods publickey\n' > "$temp_dir/ssh-expected"
for file in "$SSH_DROPIN_FILE" "$SSHD_MAIN_CONFIG" "$ROOT_SSH_DROPIN_FILE"; do
    cp "$temp_dir/ssh-expected" "$file"
done
CURRENT_SSH_PORT=6900
NEW_SSH_PORT=''
MOCK_PORTS=$'port 6900\nport 6900'
sshd() {
    if [[ "${1:-}" != '-T' ]]; then
        printf 'sshd %s\n' "$*" >> "$temp_dir/unexpected"
        return 1
    fi
    printf '%s\n' "$MOCK_PORTS"
}
systemctl() { printf 'systemctl %s\n' "$*" >> "$temp_dir/unexpected"; return 1; }
firewall_allow_ssh_port() { printf 'firewall changed\n' >> "$temp_dir/unexpected"; return 1; }

SSH_CONNECTION='' ssh_key_rotation_port "$TARGET_USER" > "$temp_dir/port"
[[ "$(cat "$temp_dir/port")" == '6900' ]]
MOCK_PORTS=$'port 22\nport 6900'
[[ "$(SSH_CONNECTION='' ssh_key_rotation_port "$TARGET_USER" <<< $'8080\n6900' 2>/dev/null)" == '6900' ]]
[[ "$(SSH_CONNECTION='192.0.2.1 40000 192.0.2.2 7000' ssh_key_rotation_port "$TARGET_USER")" == '7000' ]]
MOCK_PORTS='port 6900'

cp "$temp_dir/original" "$TARGET_AUTH_KEYS"
if SSH_CONNECTION='' rotate_ssh_key_interactive <<< "$TARGET_USER" > "$temp_dir/output" 2>&1; then
    printf 'FAIL: standalone rotation cannot replace keys with restrictions\n'
    exit 1
fi
grep -Fq '含限制选项' "$temp_dir/output"
cmp "$temp_dir/original" "$TARGET_AUTH_KEYS"
assert_clean

printf '# Keep this comment\n\n%s\n' "$old_key" > "$temp_dir/plain"
cp "$temp_dir/plain" "$TARGET_AUTH_KEYS"
add_restriction_before_stage=1
if SSH_CONNECTION='' rotate_ssh_key_interactive <<< "$TARGET_USER" > "$temp_dir/output" 2>&1; then
    printf 'FAIL: new restrictions must be checked again before staging\n'
    exit 1
fi
grep -Fq '公钥文件含非标准授权条目' "$temp_dir/output"
cmp "$temp_dir/original" "$TARGET_AUTH_KEYS"
assert_clean
add_restriction_before_stage=0

cp "$temp_dir/plain" "$TARGET_AUTH_KEYS"
confirm_new_login=0
if SSH_CONNECTION='' rotate_ssh_key_interactive <<< "$TARGET_USER" > "$temp_dir/output" 2>&1; then
    printf 'FAIL: a failed login test must not remove old keys\n'
    exit 1
fi
grep -Fq '未移除现有公钥' "$temp_dir/output"
cmp "$temp_dir/plain" "$TARGET_AUTH_KEYS"
assert_clean

confirm_new_login=1
SSH_CONNECTION='' rotate_ssh_key_interactive <<< "$TARGET_USER" > "$temp_dir/output" 2>&1
grep -Fq '只更换公钥，不修改 SSH 端口、登录策略或防火墙' "$temp_dir/output"
grep -Fq ' -p 6900 ' "$temp_dir/output"
grep -Fq '已移除旧公钥' "$temp_dir/output"
if grep -Fq -- "$old_key" "$TARGET_AUTH_KEYS"; then
    printf 'FAIL: standalone rotation did not remove the old key after verification\n'
    exit 1
fi
grep -Fxq '# Keep this comment' "$TARGET_AUTH_KEYS"
[[ "$(ssh-keygen -lf "$TARGET_AUTH_KEYS" | wc -l | tr -d ' ')" == '1' ]]
[[ "$CURRENT_SSH_PORT" == '6900' && -z "$NEW_SSH_PORT" && ! -e "$temp_dir/unexpected" ]]
for file in "$SSH_DROPIN_FILE" "$SSHD_MAIN_CONFIG" "$ROOT_SSH_DROPIN_FILE"; do
    cmp "$temp_dir/ssh-expected" "$file"
done
assert_clean
printf 'standalone SSH key rotation preserves port, login policy and service: OK\n'
