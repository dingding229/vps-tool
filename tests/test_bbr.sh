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
mkdir -p "$mock_dir" "${temp_dir}/state" "${temp_dir}/log" "${temp_dir}/systemd"
cat > "${mock_dir}/systemctl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_SYSTEMCTL_LOG:?}"
exit 0
MOCK
cat > "${mock_dir}/systemd-run" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_SYSTEMD_RUN_LOG:?}"
exit 0
MOCK
cat > "${mock_dir}/dpkg-query" <<'MOCK'
#!/usr/bin/env bash
cat <<'OUT'
ii  linux-image-6.12.3-joeyblog-bbrv3:amd64
ii  linux-headers-6.12.3-joeyblog-bbrv3:amd64
ii  linux-image-6.13.1-joeyblog-bbrv3-max:amd64
OUT
MOCK
chmod +x "${mock_dir}/systemctl" "${mock_dir}/systemd-run" "${mock_dir}/dpkg-query"
export MOCK_SYSTEMCTL_LOG="${temp_dir}/systemctl.log"
export MOCK_SYSTEMD_RUN_LOG="${temp_dir}/systemd-run.log"
old_path="$PATH"
PATH="${mock_dir}:$PATH"
export PATH

APP_STATE_DIR="${temp_dir}/state"
APP_LOG_DIR="${temp_dir}/log"
APP_LOG_FILE="${APP_LOG_DIR}/install.log"
BBR_STATE_FILE="${APP_STATE_DIR}/bbr.conf"
BBR_RESUME_UNIT_FILE="${temp_dir}/systemd/vps-tool-bbr-resume.service"
BBR_SYSCTL_FILE="${temp_dir}/99-vps-tool-bbr.conf"
touch "$APP_LOG_FILE" "$MOCK_SYSTEMCTL_LOG" "$MOCK_SYSTEMD_RUN_LOG"
source lib/bbr.sh

[[ "$(latest_installed_bbr_kernel)" == "6.13.1-joeyblog-bbrv3-max" ]]
printf 'BBRv3 installed-kernel detection: OK\n'

setup_bbr_resume_service
grep -q -- '--bbr-resume' "$BBR_RESUME_UNIT_FILE"
grep -q 'ExecStartPre=/bin/sleep 10' "$BBR_RESUME_UNIT_FILE"
grep -q 'systemd-modules-load.service systemd-sysctl.service' "$BBR_RESUME_UNIT_FILE"
grep -q 'enable vps-tool-bbr-resume.service' "$MOCK_SYSTEMCTL_LOG"
printf 'BBRv3 resume service creation: OK\n'

handoff_installer="${temp_dir}/handoff-installer.sh"
cat > "$handoff_installer" <<'HANDOFF'
#!/usr/bin/env bash
echo -n "是否立即重启？ (y/n): "
read -r REBOOT_NOW
if [[ "$REBOOT_NOW" == "y" ]]; then
    reboot
else
    echo "请记得稍后手动重启"
fi
HANDOFF
chmod 700 "$handoff_installer"
prepare_bbr_installer_reboot_handoff "$handoff_installer"
grep -q '^REBOOT_NOW="n"$' "$handoff_installer"
if grep -q '^read -r REBOOT_NOW$\|是否立即重启\|请记得稍后手动重启' "$handoff_installer"; then
    printf 'FAIL: upstream reboot prompt was not handed off\n'
    exit 1
fi
printf 'BBRv3 reboot prompt handoff: OK\n'

installer_dir="${temp_dir}/installer"
mkdir -p "$installer_dir"
cat > "${installer_dir}/upstream.sh" <<'UPSTREAM'
#!/usr/bin/env bash
set -e
printf 'before reboot\n'
sudo reboot
printf 'continued after intercepted reboot\n'
UPSTREAM
chmod +x "${installer_dir}/upstream.sh"
run_bbr_installer_guarded "${installer_dir}/upstream.sh" "$installer_dir" "${installer_dir}/session.log"
[[ -f "${installer_dir}/reboot-requested" ]]
grep -q 'continued after intercepted reboot' "${installer_dir}/session.log"
printf 'BBRv3 upstream reboot interception: OK\n'

cat > "${installer_dir}/failed.sh" <<'FAILED'
#!/usr/bin/env bash
exit 7
FAILED
chmod +x "${installer_dir}/failed.sh"
if run_bbr_installer_guarded "${installer_dir}/failed.sh" "$installer_dir" "${installer_dir}/failed.log"; then
    printf 'FAIL: upstream installer failure was ignored\n'
    exit 1
fi
printf 'BBRv3 upstream failure propagation: OK\n'

current_boot_id() { printf 'new-boot-id'; }
uname() {
    if [[ "${1:-}" == "-r" ]]; then printf '6.13.1-joeyblog-bbrv3-max\n'; else command uname "$@"; fi
}
modinfo() {
    [[ "${1:-}" == "tcp_bbr" ]] && printf 'version: 3\n'
}
sysctl() {
    case "$*" in
        '-n net.ipv4.tcp_congestion_control') printf 'bbr\n' ;;
        '-n net.core.default_qdisc') printf 'fq\n' ;;
        *) return 0 ;;
    esac
}
persist_bbr_runtime_defaults() { return 0; }
remove_bbr_resume_service() { :; }
cat > "$BBR_STATE_FILE" <<'STATE'
STATUS=pending_reboot
REBOOT_REQUIRED=yes
TARGET_KERNEL=6.13.1-joeyblog-bbrv3-max
ORIGINAL_BOOT_ID=old-boot-id
ORIGINAL_KERNEL=6.1.0-generic
NOTIFIED=yes
STATE
resume_bbr_after_reboot
grep -q '^STATUS=active$' "$BBR_STATE_FILE"
grep -q '^REBOOT_REQUIRED=no$' "$BBR_STATE_FILE"
grep -q '^CURRENT_BOOT_ID=new-boot-id$' "$BBR_STATE_FILE"
grep -q '^BBR_VERSION=3$' "$BBR_STATE_FILE"
grep -q '^CONGESTION_CONTROL=bbr$' "$BBR_STATE_FILE"
printf 'BBRv3 post-reboot verification: OK\n'

notice="$(notify_bbr_resume_result)"
grep -q 'BBRv3 重启恢复完成' <<< "$notice"
grep -q '^NOTIFIED=yes$' "$BBR_STATE_FILE"
printf 'BBRv3 resume notification: OK\n'

cat > "$BBR_STATE_FILE" <<'STATE'
STATUS=verification_failed
REBOOT_REQUIRED=no
TARGET_KERNEL=6.13.1-joeyblog-bbrv3-max
ORIGINAL_BOOT_ID=old-boot-id
ORIGINAL_KERNEL=6.1.0-generic
MESSAGE=CURRENT_KERNEL_NOT_BBRV3
NOTIFIED=yes
STATE
status_view="$(show_bbr_status)"
grep -q '重启后验证通过' <<< "$status_view"
grep -q '^STATUS=active$' "$BBR_STATE_FILE"
printf 'BBRv3 stale failure reconciliation: OK\n'

BBR_REBOOT_SCHEDULED=no
BBR_REBOOT_DELAY=8
schedule_bbr_reboot >/dev/null
[[ "$BBR_REBOOT_SCHEDULED" == "yes" ]]
grep -q -- '--on-active=8s' "$MOCK_SYSTEMD_RUN_LOG"
grep -q 'systemctl reboot' "$MOCK_SYSTEMD_RUN_LOG"
printf 'BBRv3 delayed reboot scheduling: OK\n'

grep -q 'resume_bbr_after_reboot' vps-init.sh
grep -q -- '--bbr-resume' vps-init.sh
grep -q '安全重启 / 开机自动恢复' lib/menu.sh
grep -q '重启后自动恢复检查' lib/bbr.sh
printf 'BBRv3 integration tests: OK\n'

PATH="$old_path"
