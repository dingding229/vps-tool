#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh
source lib/apt.sh
source lib/preflight.sh
source lib/ssh.sh
source lib/fail2ban.sh
source lib/bbr.sh
source lib/status.sh
source lib/menu.sh

# 中文宽度对齐：4 个中文字符占 8 列，补齐到 16 列。
padded="$(ui_pad_right '操作系统' 16)"
width="$(python3 - "$padded" <<'PY'
import sys, unicodedata
print(sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W','F') else 1 for c in sys.argv[1]))
PY
)"
[[ "$width" == "16" ]]

# 页面区块必须按编号输出，键值起始位置保持一致。
layout="$(
    ui_header
    ui_title '系统状态总览'
    ui_section '01' '运行环境'
    ui_kv '操作系统' 'Debian GNU/Linux 12'
    ui_kv 'CPU 架构' 'x86_64'
    ui_section '02' 'SSH 安全'
    ui_kv 'SSH 服务' 'active'
)"
grep -q '^01  运行环境$' <<< "$layout"
grep -q '^02  SSH 安全$' <<< "$layout"
grep -q '北京时间' <<< "$layout"

# Fail2ban 状态必须格式化，不能泄漏 fail2ban-client 原始 Status 树。
mock_dir="$(mktemp -d)"
cat > "${mock_dir}/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "${1:-}" in
    is-active) printf 'active\n' ;;
    is-enabled) printf 'enabled\n' ;;
esac
MOCK
cat > "${mock_dir}/fail2ban-client" <<'MOCK'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
    printf '1.0.2\n'
elif [[ "${1:-}" == "status" && "${2:-}" == "sshd" ]]; then
    cat <<'OUT'
Status for the jail: sshd
|- Filter
|  |- Currently failed: 2
|  `- Total failed: 18
`- Actions
   |- Currently banned: 3
   |- Total banned: 9
   `- Banned IP list: 203.0.113.10 198.51.100.2
OUT
elif [[ "${1:-}" == "status" ]]; then
    cat <<'OUT'
Status
|- Number of jail: 1
`- Jail list: sshd
OUT
fi
MOCK
chmod +x "${mock_dir}/systemctl" "${mock_dir}/fail2ban-client"
old_path="$PATH"
PATH="${mock_dir}:$PATH"
fail2ban_view="$(print_fail2ban_status)"
PATH="$old_path"
python3 - "$mock_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]))
PY
grep -q '活动 Jail' <<< "$fail2ban_view"
grep -q '当前封禁' <<< "$fail2ban_view"
grep -q '203.0.113.10' <<< "$fail2ban_view"
if grep -q '^Status\|Number of jail\|Jail list' <<< "$fail2ban_view"; then
    printf 'FAIL: raw fail2ban status leaked into UI\n'
    exit 1
fi


# 主菜单必须按功能域排列，相近操作放在同一区域，且不展示内部阶段措辞。
main_menu_view="$(main_menu <<< '0' 2>/dev/null)"
python3 - "$main_menu_view" <<'PY_MENU'
import sys
text = sys.argv[1]
labels = ["快速开始", "SSH 与登录", "访问防护", "网络与流量", "系统维护", "其他"]
positions = [text.index(label) for label in labels]
assert positions == sorted(positions)
for phrase in ("第一" + "版", "测试" + "版", "安装或" + "修复"):
    assert phrase not in text
line9 = next(line for line in text.splitlines() if "[9]" in line)
line10 = next(line for line in text.splitlines() if "[10]" in line)
line11 = next(line for line in text.splitlines() if "[11]" in line)
line12 = next(line for line in text.splitlines() if "[12]" in line)
assert line9.index("查看系统状态") == line10.index("检查系统配置")
assert line10.index("检查系统配置") == line11.index("APT 软件包更新")
assert line11.index("APT 软件包更新") == line12.index("检查 VPS Tool 更新")
PY_MENU
grep -q '执行 SSH 配置回滚' <<< "$main_menu_view"
grep -q 'vnStat 流量中心' <<< "$main_menu_view"
grep -q 'APT 软件包更新' <<< "$main_menu_view"
grep -q '检查 VPS Tool 更新' <<< "$main_menu_view"
printf 'main menu grouping: OK\n'

# 系统状态页按“环境 → APT → SSH → 防护 → 流量 → 网络 → 更新 → 文件”排列。
show_preflight() { ui_section "$1" "运行环境"; }
print_apt_status() { ui_kv "APT 状态" "✔ 已是最新版本"; }
show_ssh_status() { :; }
print_fail2ban_status() { :; }
print_vnstat_status() { :; }
show_bbr_status() { :; }
print_update_status() { :; }
status_view="$(show_full_status)"
python3 - "$status_view" <<'PY_STATUS'
import sys
text = sys.argv[1]
labels = [
    "01  运行环境",
    "02  系统软件 / APT",
    "03  SSH 安全",
    "04  Fail2ban 防护",
    "05  vnStat 流量监控",
    "06  网络加速",
    "07  VPS Tool 更新",
    "08  文件与备份",
]
positions = [text.index(label) for label in labels]
assert positions == sorted(positions)
PY_STATUS
printf 'status page ordering: OK\n'

printf 'ui layout tests: OK\n'
