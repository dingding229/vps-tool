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
