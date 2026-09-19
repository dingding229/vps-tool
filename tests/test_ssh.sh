#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh
source lib/ssh.sh

temp_dir="$(mktemp -d)"
cleanup() {
    python3 - "$temp_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT
SSH_DROPIN_FILE="${temp_dir}/00-vps-tool.conf"

write_ssh_dropin 6900 prohibit-password no
if grep -qE '^[[:space:]]*Port[[:space:]]+' "$SSH_DROPIN_FILE"; then
    printf 'FAIL: unchanged SSH port should be omitted from drop-in\n'
    exit 1
fi
write_ssh_dropin 6900 prohibit-password yes
grep -q '^Port 6900$' "$SSH_DROPIN_FILE"
printf 'SSH drop-in port selection: OK\n'

MOCK_PORTS='6900'
sshd() {
    if [[ "${1:-}" == "-t" ]]; then
        return 0
    fi
    for port in $MOCK_PORTS; do
        printf 'port %s\n' "$port"
    done
    printf '%s\n' \
        'pubkeyauthentication yes' \
        'passwordauthentication no' \
        'kbdinteractiveauthentication no' \
        'authenticationmethods publickey' \
        "permitrootlogin ${MOCK_PERMIT_ROOT:-prohibit-password}"
}

MOCK_PORTS='6900 6900'
verify_effective_ssh_config 6900 root
ssh_key_only_login_is_effective root

MOCK_PERMIT_ROOT='no'
if ssh_key_only_login_is_effective root; then
    printf 'FAIL: disabled root login must not skip root connection verification\n'
    exit 1
fi
ssh_key_only_login_is_effective ubuntu
MOCK_PERMIT_ROOT='prohibit-password'

MOCK_PORTS='22 6900'
if verify_effective_ssh_config 6900 root; then
    printf 'FAIL: distinct effective SSH ports should be rejected\n'
    exit 1
fi
printf 'duplicate SSH port verification: OK\n'

# 当前端口来自其他配置时，不应在工具 drop-in 中重复写入。
printf 'PubkeyAuthentication yes\n' > "$SSH_DROPIN_FILE"
MOCK_PORTS='6900'
if should_write_ssh_port 6900 6900 root; then
    printf 'FAIL: external unchanged SSH port should not be duplicated\n'
    exit 1
fi

# 当前端口仅由工具自身管理时必须保留，否则会回退到 OpenSSH 默认端口。
printf 'Port 6900\n' > "$SSH_DROPIN_FILE"
MOCK_PORTS='6900'
should_write_ssh_port 6900 6900 root

# 如果已有多个相同声明，工具应删除自己的重复 Port 行。
MOCK_PORTS='6900 6900'
if should_write_ssh_port 6900 6900 root; then
    printf 'FAIL: duplicate managed SSH port should be omitted\n'
    exit 1
fi
printf 'unchanged SSH port skip logic: OK\n'
