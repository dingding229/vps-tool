#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
# shellcheck disable=SC1091
source config/defaults.conf
# shellcheck disable=SC1091
source lib/common.sh
# shellcheck disable=SC1091
source lib/user.sh
# shellcheck disable=SC1091
source lib/fail2ban-log.sh

assert_ok() { "$@" || { printf 'FAIL: %q ' "$@"; printf '\n'; exit 1; }; }
assert_fail() { if "$@"; then printf 'FAIL (expected failure): %q ' "$@"; printf '\n'; exit 1; fi; }

assert_ok validate_port 1
assert_ok validate_port 22
assert_ok validate_port 65535
assert_fail validate_port 0
assert_fail validate_port 65536
assert_fail validate_port abc

assert_ok validate_positive_integer 1
assert_ok validate_positive_integer 365
assert_fail validate_positive_integer 0
assert_fail validate_positive_integer -1

assert_ok validate_ip 127.0.0.1
assert_ok validate_ip 2001:db8::1
assert_fail validate_ip '127.0.0.1;id'
assert_fail validate_ip 'not-an-ip'

assert_ok validate_public_key_line 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE0X82O40SXgO4Av3Q9xLtDXrs1jFzCvcgU7HOo47t15 test@example'
assert_fail validate_public_key_line 'ssh-ed25519 invalid'

printf 'helper tests: OK\n'


# 所有确认均为 Y/N，直接回车默认为 Y。
printf '\n' | confirm "默认确认测试" "Y"
if printf 'N\n' | confirm "否定确认测试" "Y"; then
    printf 'FAIL: N should return failure\n'
    exit 1
fi
printf 'invalid\n\n' | confirm "非法输入后默认确认测试" "Y"
printf 'confirmation flow: OK\n'

# 自动生成密钥流程：模拟用户已下载并验证，私钥应删除、公钥应保留。
original_user="$(id -un)"
original_home="${HOME}"
temp_home="$(mktemp -d)"
TARGET_USER="$original_user"
TARGET_HOME="$temp_home"
TARGET_AUTH_KEYS="${temp_home}/.ssh/authorized_keys"
mkdir -p "${temp_home}/.ssh"
touch "$TARGET_AUTH_KEYS"
confirm() { return 0; }
generate_authorized_key 22 >/dev/null
[[ -s "$TARGET_AUTH_KEYS" ]]
has_valid_authorized_key
[[ -z "$GENERATED_PRIVATE_KEY" ]]
[[ -z "$(find "${temp_home}/.ssh" -maxdepth 1 -type f ! -name authorized_keys -print -quit)" ]]
rm -rf "$temp_home"
TARGET_USER="$original_user"
TARGET_HOME="$original_home"
printf 'generated key flow: OK\n'

# 取消自动生成流程：临时私钥和刚加入的公钥都必须删除。
temp_home="$(mktemp -d)"
TARGET_USER="$original_user"
TARGET_HOME="$temp_home"
TARGET_AUTH_KEYS="${temp_home}/.ssh/authorized_keys"
mkdir -p "${temp_home}/.ssh"
touch "$TARGET_AUTH_KEYS"
confirm_call=0
confirm() {
    confirm_call=$((confirm_call + 1))
    case "$confirm_call" in
        1|2) return 1 ;;
        3) return 0 ;;
    esac
    return 1
}
if generate_authorized_key 22 >/dev/null; then
    printf 'FAIL: cancelled key generation unexpectedly succeeded\n'
    exit 1
fi
[[ ! -s "$TARGET_AUTH_KEYS" ]]
[[ -z "$(find "${temp_home}/.ssh" -maxdepth 1 -type f ! -name authorized_keys -print -quit)" ]]
rm -rf "$temp_home"
TARGET_USER="$original_user"
TARGET_HOME="$original_home"
printf 'cancelled key flow: OK\n'

# Fail2ban 日志必须结构化显示，不能直接回显原始组件行。
sample_logs="$(cat <<'LOGS'
2026-09-19 04:40:43,676 fail2ban.filter [471]: INFO [sshd] Found 124.161.224.81 - 2026-09-19 04:40:43
2026-09-19 04:48:23,200 fail2ban.actions [51929]: NOTICE [sshd] Restore Ban 125.122.39.115
2026-09-19 04:49:00,000 fail2ban.actions [51929]: NOTICE [sshd] Ban 203.0.113.10
2026-09-19 04:49:01,000 fail2ban.server [51929]: ERROR Something failed badly
LOGS
)"
formatted_logs="$(render_fail2ban_logs "$sample_logs")"
grep -q '失败尝试' <<< "$formatted_logs"
grep -q '恢复封禁' <<< "$formatted_logs"
grep -q '封禁' <<< "$formatted_logs"
grep -q '异常' <<< "$formatted_logs"
grep -q '摘要' <<< "$formatted_logs"
if grep -q 'fail2ban.actions' <<< "$formatted_logs"; then
    printf 'FAIL: raw Fail2ban log component leaked into formatted output\n'
    exit 1
fi
printf 'formatted fail2ban logs: OK\n'
