#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh
source lib/update.sh

version_is_newer 0.5.0 0.5.1
version_is_newer 0.5.9 0.6.0
version_is_newer 1.9.9 2.0.0
if version_is_newer 0.5.0 0.5.0; then
    printf 'FAIL: equal version treated as update\n'
    exit 1
fi
if version_is_newer 0.6.0 0.5.9; then
    printf 'FAIL: older version treated as update\n'
    exit 1
fi
if normalize_app_version 'next'; then
    printf 'FAIL: invalid version accepted\n'
    exit 1
fi
printf 'update version comparison: OK\n'

temp_dir="$(mktemp -d)"
cleanup() {
    python3 - "$temp_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT

fake_install="${temp_dir}/vps-tool"
payload_root="${temp_dir}/payload"
payload="${payload_root}/vps-tool-main"
mkdir -p "$fake_install/config" "$payload/config" "$payload/lib" "$payload/scripts" "${temp_dir}/state"
printf 'old\n' > "${fake_install}/old-marker"
printf '#!/usr/bin/env bash\n' > "${fake_install}/vps-init.sh"
printf '#!/usr/bin/env bash\necho new\n' > "${payload}/vps-init.sh"
printf '#!/usr/bin/env bash\n' > "${payload}/install.sh"
printf 'APP_VERSION="0.5.1"\n' > "${payload}/config/defaults.conf"
printf '#!/usr/bin/env bash\n' > "${payload}/lib/common.sh"
printf '#!/usr/bin/env bash\n' > "${payload}/lib/update.sh"
printf '#!/usr/bin/env bash\n' > "${payload}/scripts/status.sh"
archive="${temp_dir}/update.tar.gz"
tar -czf "$archive" -C "$payload_root" vps-tool-main

SCRIPT_DIR="$fake_install"
APP_LOG_DIR="${temp_dir}/log"
APP_LOG_FILE="${APP_LOG_DIR}/install.log"
APP_STATE_DIR="${temp_dir}/state"
UPDATE_STATE_FILE="${APP_STATE_DIR}/update.conf"
mkdir -p "$APP_LOG_DIR"
touch "$APP_LOG_FILE"
MOCK_ARCHIVE="$archive"

curl() {
    local output="" arg previous=""
    for arg in "$@"; do
        if [[ "$previous" == "--output" ]]; then output="$arg"; break; fi
        previous="$arg"
    done
    if [[ -n "$output" ]]; then
        cp "$MOCK_ARCHIVE" "$output"
    else
        printf 'APP_VERSION="0.5.1"\n'
    fi
}

[[ "$(read_remote_app_version)" == '0.5.1' ]]
check_result=0
check_for_updates auto || check_result=$?
[[ "$check_result" == "10" ]]
[[ "$UPDATE_AVAILABLE_VERSION" == "0.5.1" ]]
grep -q '^STATUS=available$' "$UPDATE_STATE_FILE"
install_remote_update '0.5.1'
grep -q 'APP_VERSION="0.5.1"' "${fake_install}/config/defaults.conf"
[[ -x "${fake_install}/vps-init.sh" ]]
[[ -n "$(find "$temp_dir" -maxdepth 1 -type d -name 'vps-tool.backup.*' -print -quit)" ]]
grep -q '^STATUS=updated$' "$UPDATE_STATE_FILE"
printf 'atomic update installation: OK\n'
