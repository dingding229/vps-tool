#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
cd "$ROOT_DIR"
export NO_COLOR=1 VPS_TOOL_NO_CLEAR=1
SCRIPT_DIR="$ROOT_DIR"
source config/defaults.conf
source lib/common.sh
source lib/vnstat.sh

sample_json='{
  "vnstatversion": "2.12",
  "jsonversion": "2",
  "interfaces": [{
    "name": "eth0",
    "alias": "",
    "created": {
      "date": {"year": 2026, "month": 9, "day": 1},
      "timestamp": 1788192000
    },
    "updated": {
      "date": {"year": 2026, "month": 9, "day": 19},
      "time": {"hour": 13, "minute": 30},
      "timestamp": 1789795800
    },
    "traffic": {
      "total": {"rx": 1073741824, "tx": 536870912},
      "hour": [{
        "id": 1,
        "date": {"year": 2026, "month": 9, "day": 19},
        "time": {"hour": 13, "minute": 0},
        "timestamp": 1789794000,
        "rx": 1048576,
        "tx": 524288
      }],
      "day": [{
        "id": 1,
        "date": {"year": 2026, "month": 9, "day": 19},
        "timestamp": 1789747200,
        "rx": 1073741824,
        "tx": 536870912
      }],
      "month": [],
      "year": [],
      "top": []
    }
  }]
}'

summary="$(render_vnstat_json summary eth0 <<< "$sample_json")"
grep -q '网络接口.*eth0' <<< "$summary"
grep -q '累计接收.*1.00 GiB' <<< "$summary"
grep -q '累计发送.*512.00 MiB' <<< "$summary"
grep -q '累计流量.*1.50 GiB' <<< "$summary"
grep -q '2026-09-19 13:30:00 北京时间' <<< "$summary"
if grep -q '"interfaces"\|"traffic"\|"rx"' <<< "$summary"; then
    printf 'FAIL: raw vnStat JSON leaked into summary\n'
    exit 1
fi
printf 'vnStat formatted summary: OK\n'

hourly="$(render_vnstat_json hour eth0 <<< "$sample_json")"
grep -q '北京时间' <<< "$hourly"
grep -q '2026-09-19 13:00' <<< "$hourly"
grep -q '1.00 MiB' <<< "$hourly"
grep -q '512.00 KiB' <<< "$hourly"
grep -q '1.50 MiB' <<< "$hourly"
printf 'vnStat hourly Beijing table: OK\n'

read -r today_date today_timestamp < <(python3 - "${APP_TIMEZONE:-Asia/Shanghai}" <<'PY_TODAY'
import datetime as dt, sys
from zoneinfo import ZoneInfo
now = dt.datetime.now(ZoneInfo(sys.argv[1]))
midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
print(now.strftime("%Y-%m-%d"), int(midnight.timestamp()))
PY_TODAY
)
today_json="$(printf '{"interfaces":[{"name":"eth0","traffic":{"day":[{"timestamp":%s,"rx":1073741824,"tx":536870912}]}}]}' "$today_timestamp")"
today="$(render_vnstat_json today eth0 <<< "$today_json")"
grep -q "$today_date" <<< "$today"
grep -q '1.50 GiB' <<< "$today"
printf 'vnStat today table: OK\n'

empty_json='{"interfaces":[{"name":"eth0","created":{},"updated":{},"traffic":{"total":{"rx":0,"tx":0},"day":[]}}]}'
empty_view="$(render_vnstat_json day eth0 <<< "$empty_json")"
grep -q '还没有足够的历史流量数据' <<< "$empty_view"
printf 'vnStat empty database handling: OK\n'

set +e
invalid_view="$(render_vnstat_json summary eth0 <<< 'not-json' 2>&1)"
invalid_status=$?
set -e
[[ "$invalid_status" -ne 0 ]]
grep -q '无法解析 vnStat 数据' <<< "$invalid_view"
printf 'vnStat invalid JSON handling: OK\n'

[[ "$(vnstat_format_bytes 1073741824)" == '1.00 GiB' ]]
[[ "$(vnstat_format_bytes 1610612736)" == '1.50 GiB' ]]
[[ "$(vnstat_format_bytes 512)" == '512 B' ]]
printf 'vnStat byte formatter: OK\n'

validate_network_interface eth0
validate_network_interface 'ens3.100'
if validate_network_interface '../etc/passwd'; then
    printf 'FAIL: unsafe interface name accepted\n'
    exit 1
fi
printf 'vnStat interface validation: OK\n'

grep -q 'configure_vnstat_interactive' lib/menu.sh
grep -q 'vnstat_menu' lib/menu.sh
grep -q -- '--vnstat' vps-init.sh
grep -q 'vnStat 流量监控' lib/status.sh
grep -q 'vnStat 流量监控检查' lib/verify.sh
printf 'vnStat menu and integration: OK\n'


# vnStat 查询项保持连续，安装、接口和状态集中在配置区域。
vnstat_menu_view="$(vnstat_menu <<< '0' 2>/dev/null)"
python3 - "$vnstat_menu_view" <<'PY_VNSTAT_MENU'
import sys
text = sys.argv[1]
labels = ["流量查询", "配置与状态", "其他"]
positions = [text.index(label) for label in labels]
assert positions == sorted(positions)
assert text.index("今日流量") < text.index("安装与配置 vnStat")
PY_VNSTAT_MENU
printf 'vnStat menu grouping: OK\n'
