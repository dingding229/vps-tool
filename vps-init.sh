#!/usr/bin/env bash
set -Euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config/defaults.conf"
for module in common preflight firewall user rollback ssh logrotate fail2ban fail2ban-log bbr verify status menu; do
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/lib/${module}.sh"
done


usage() {
    cat <<EOF_USAGE
${APP_NAME} ${APP_VERSION}

用法：sudo bash vps-init.sh [选项]

选项：
  --interactive       进入交互模式（默认）
  --all               执行完整配置流程
  --status            查看系统状态
  --verify            验证配置
  --fail2ban-logs     进入 Fail2ban 日志中心
  --rollback          立即执行待处理 SSH 回滚
  --no-clear          不清理终端画面
  --help              显示帮助

说明：第一版的 SSH、Fail2ban 和 BBRv3 配置建议在 VPS 控制台可用时执行。
EOF_USAGE
}

main() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage
        return 0
    fi
    require_root
    initialize_runtime
    acquire_lock
    case "${1:---interactive}" in
        --interactive) main_menu ;;
        --all) run_all ;;
        --status) show_full_status ;;
        --verify) verify_system ;;
        --fail2ban-logs) fail2ban_log_menu ;;
        --rollback) run_ssh_rollback_now ;;
        --no-clear) export VPS_TOOL_NO_CLEAR=1; main_menu ;;
        --help|-h) usage ;;
        *) usage; return 2 ;;
    esac
}

main "$@"
