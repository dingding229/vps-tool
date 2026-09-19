#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh

temp_dir="$(mktemp -d)"
cleanup() {
    python3 - "$temp_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT

mock_dir="${temp_dir}/bin"
mkdir -p "$mock_dir" "${temp_dir}/state" "${temp_dir}/log"
cat > "${mock_dir}/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "${mock_dir}/apt-get" <<'MOCK'
#!/usr/bin/env bash
set -eu
args=" $* "
mode="${MOCK_APT_MODE:-current}"
state_file="${MOCK_APT_STATE_FILE:?}"

if [[ "$args" == *" update "* ]]; then
    [[ "$mode" != "index-fail" ]] || exit 100
    printf 'Hit:1 https://deb.example stable InRelease\n'
    exit 0
fi

if [[ "$args" == *" -s "* && "$args" == *" upgrade "* ]]; then
    [[ "$mode" != "check-fail" ]] || exit 100
    if [[ "$mode" == "current" || -f "$state_file" ]]; then
        printf '0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.\n'
    elif [[ "$mode" == "held-back" ]]; then
        cat <<'OUT'
The following packages have been kept back:
  linux-image-amd64 linux-headers-amd64
0 upgraded, 0 newly installed, 0 to remove and 2 not upgraded.
OUT
    else
        cat <<'OUT'
Reading package lists...
Inst openssl [3.0.11] (3.0.14 Debian:12/stable [amd64])
Inst curl [7.88.1] (7.88.2 Debian:12/stable [amd64])
Inst linux-image-amd64 [6.1.0] (6.1.1 Debian:12/stable [amd64])
3 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
OUT
    fi
    exit 0
fi

if [[ "$args" == *" upgrade "* ]]; then
    [[ "$mode" != "upgrade-fail" ]] || exit 100
    : > "$state_file"
    printf 'upgrade complete\n'
    exit 0
fi

exit 2
MOCK
chmod +x "${mock_dir}/apt-get" "${mock_dir}/dpkg-query"

old_path="$PATH"
PATH="${mock_dir}:$PATH"
export PATH
export MOCK_APT_STATE_FILE="${temp_dir}/upgraded"
APP_STATE_DIR="${temp_dir}/state"
APP_LOG_DIR="${temp_dir}/log"
APP_LOG_FILE="${APP_LOG_DIR}/install.log"
APT_STATE_FILE="${APP_STATE_DIR}/apt.conf"
APT_PACKAGE_PREVIEW_LIMIT=2
touch "$APP_LOG_FILE"
source lib/apt.sh

MOCK_APT_MODE=current
export MOCK_APT_MODE
refresh_apt_indexes
read_apt_upgrade_status
[[ "$APT_UPGRADABLE_COUNT" == "0" ]]
[[ -z "$APT_UPGRADABLE_PACKAGES" ]]
printf 'APT current-state detection: OK\n'

MOCK_APT_MODE=held-back
export MOCK_APT_MODE
read_apt_upgrade_status
[[ "$APT_UPGRADABLE_COUNT" == "2" ]]
printf 'APT held-package detection: OK\n'

MOCK_APT_MODE=updates
export MOCK_APT_MODE
read_apt_upgrade_status
[[ "$APT_UPGRADABLE_COUNT" == "3" ]]
[[ "$(wc -l <<< "$APT_UPGRADABLE_PACKAGES" | tr -d ' ')" == "2" ]]
preview="$(print_apt_package_preview)"
grep -q 'openssl 3.0.14' <<< "$preview"
grep -q 'curl 7.88.2' <<< "$preview"
grep -q '其余 1 个软件包' <<< "$preview"
if grep -q 'Inst \|Reading package lists' <<< "$preview"; then
    printf 'FAIL: raw apt simulation output leaked into UI\n'
    exit 1
fi
printf 'APT formatted update preview: OK\n'

rm -f "$APT_STATE_FILE" "$MOCK_APT_STATE_FILE"
check_apt_before_startup --status
[[ "$(awk -F= '$1=="STATUS" {print $2}' "$APT_STATE_FILE")" == "updates_available" ]]
[[ "$(awk -F= '$1=="UPGRADABLE_COUNT" {print $2}' "$APT_STATE_FILE")" == "3" ]]
grep -Eq '^CHECKED_AT=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\+0800$' "$APT_STATE_FILE"
printf 'APT startup state recording: OK\n'

upgrade_apt_packages
[[ -f "$MOCK_APT_STATE_FILE" ]]
grep -q '^STATUS=current$' "$APT_STATE_FILE"
grep -q '^UPGRADABLE_COUNT=0$' "$APT_STATE_FILE"
printf 'APT upgrade flow: OK\n'

rm -f "$MOCK_APT_STATE_FILE"
MOCK_APT_MODE=upgrade-fail
export MOCK_APT_MODE
read_apt_upgrade_status
if upgrade_apt_packages; then
    printf 'FAIL: failed apt upgrade returned success\n'
    exit 1
fi
grep -q '^STATUS=upgrade_failed$' "$APT_STATE_FILE"
printf 'APT upgrade failure handling: OK\n'

MOCK_APT_MODE=index-fail
export MOCK_APT_MODE
check_apt_before_startup --status
grep -q '^STATUS=index_failed$' "$APT_STATE_FILE"
printf 'APT index failure handling: OK\n'

status_view="$(print_apt_status)"
grep -q 'APT 状态' <<< "$status_view"
grep -q '检查或升级失败' <<< "$status_view"
grep -q '北京时间' <<< "$status_view"

PATH="$old_path"
printf 'APT tests: OK\n'
