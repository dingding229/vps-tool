#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
source config/defaults.conf
source lib/common.sh
source lib/user.sh

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
confirm() {
    case "$1" in
        '是否保留现有 SSH 密钥'*|'是否在当前终端显示私钥') return 1 ;;
        '是否已保存新私钥并使用它成功登录，确认后移除旧公钥')
            grep -Fq -- "$old_key" "$TARGET_AUTH_KEYS" || exit 1
            grep -Fxq -- "$GENERATED_PUBLIC_KEY_LINE" "$TARGET_AUTH_KEYS" || exit 1
            [[ -s "$GENERATED_PRIVATE_KEY" ]] || exit 1
            if [[ "$change_during_test" == "1" ]]; then
                cat "$temp_dir/extra.pub" >> "$TARGET_AUTH_KEYS"
            fi
            return 0
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
