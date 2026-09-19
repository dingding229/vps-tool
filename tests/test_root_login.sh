#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh
source lib/user.sh
source lib/root-login.sh

temp_dir="$(mktemp -d)"
cleanup() {
    python3 - "$temp_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT

ROOT_SSH_DROPIN_FILE="${temp_dir}/root-access.conf"
write_root_access_dropin key
grep -q '^Match User root$' "$ROOT_SSH_DROPIN_FILE"
grep -q '^    PermitRootLogin prohibit-password$' "$ROOT_SSH_DROPIN_FILE"
grep -q '^    PasswordAuthentication no$' "$ROOT_SSH_DROPIN_FILE"
grep -q '^    AuthenticationMethods publickey$' "$ROOT_SSH_DROPIN_FILE"

write_root_access_dropin password
grep -q '^    PermitRootLogin yes$' "$ROOT_SSH_DROPIN_FILE"
grep -q '^    PasswordAuthentication yes$' "$ROOT_SSH_DROPIN_FILE"
grep -q '^    AuthenticationMethods any$' "$ROOT_SSH_DROPIN_FILE"
printf 'root drop-in generation: OK\n'

SSHD_MAIN_CONFIG="${temp_dir}/main-sshd_config"
printf 'PasswordAuthentication no\nInclude %s\n' "$ROOT_SSH_DROPIN_FILE" > "$SSHD_MAIN_CONFIG"
chmod 640 "$SSHD_MAIN_CONFIG"
ensure_root_access_include_first
[[ "$(head -n 1 "$SSHD_MAIN_CONFIG")" == "Include ${ROOT_SSH_DROPIN_FILE}" ]]
[[ "$(grep -cFx "Include ${ROOT_SSH_DROPIN_FILE}" "$SSHD_MAIN_CONFIG")" == "1" ]]
mode="$(python3 - "$SSHD_MAIN_CONFIG" <<'PY'
import os, stat, sys
print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode))[2:])
PY
)"
[[ "$mode" == "640" ]]
printf 'root include ordering and mode preservation: OK\n'

# 如果本机提供 sshd，则验证最前置 Include 只覆盖 root，不改变普通用户认证策略。
if command -v sshd >/dev/null 2>&1 && command -v ssh-keygen >/dev/null 2>&1; then
    host_key="${temp_dir}/ssh_host_ed25519_key"
    ssh-keygen -q -t ed25519 -N '' -f "$host_key"
    cat > "${temp_dir}/root-key.conf" <<'CONF'
Match User root
    PermitRootLogin prohibit-password
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
Match all
CONF
    cat > "${temp_dir}/root-password.conf" <<'CONF'
Match User root
    PermitRootLogin yes
    PubkeyAuthentication yes
    PasswordAuthentication yes
    KbdInteractiveAuthentication no
    AuthenticationMethods any
Match all
CONF
    cat > "${temp_dir}/base.conf" <<CONF
HostKey ${host_key}
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AuthenticationMethods publickey
CONF

    check_effective() {
        local override="$1" user="$2"
        cat > "${temp_dir}/sshd_config" <<CONF
Include ${override}
Include ${temp_dir}/base.conf
CONF
        sshd -T -f "${temp_dir}/sshd_config" \
            -C "user=${user},host=localhost,addr=127.0.0.1"
    }

    root_key="$(check_effective "${temp_dir}/root-key.conf" root)"
    grep -q '^permitrootlogin prohibit-password$' <<< "$root_key"
    grep -q '^passwordauthentication no$' <<< "$root_key"
    grep -q '^authenticationmethods publickey$' <<< "$root_key"

    root_password="$(check_effective "${temp_dir}/root-password.conf" root)"
    grep -q '^permitrootlogin yes$' <<< "$root_password"
    grep -q '^passwordauthentication yes$' <<< "$root_password"
    grep -q '^authenticationmethods any$' <<< "$root_password"

    nonroot="$(check_effective "${temp_dir}/root-password.conf" ubuntu)"
    grep -q '^permitrootlogin no$' <<< "$nonroot"
    grep -q '^passwordauthentication no$' <<< "$nonroot"
    grep -q '^authenticationmethods publickey$' <<< "$nonroot"
    printf 'root-only SSH override: OK\n'
fi
