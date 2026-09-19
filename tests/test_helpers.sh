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

# 自动生成密钥流程：模拟用户已下载并验证，私钥应删除、公钥应保留。
original_user="$(id -un)"
original_home="${HOME}"
temp_home="$(mktemp -d)"
TARGET_USER="$original_user"
TARGET_HOME="$temp_home"
TARGET_AUTH_KEYS="${temp_home}/.ssh/authorized_keys"
mkdir -p "${temp_home}/.ssh"
touch "$TARGET_AUTH_KEYS"
prompt_value() { printf 'KEY_READY'; }
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
prompt_value() { printf 'CANCEL'; }
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
