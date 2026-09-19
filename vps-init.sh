#!/usr/bin/env bash
set -Euo pipefail

resolve_script_dir() {
    local source_path="${BASH_SOURCE[0]}" source_dir link_target
    while [[ -L "$source_path" ]]; do
        source_dir="$(cd -P -- "$(dirname -- "$source_path")" >/dev/null 2>&1 && pwd)" \
            || return 1
        link_target="$(readlink -- "$source_path")" || return 1
        if [[ "$link_target" == /* ]]; then
            source_path="$link_target"
        else
            source_path="${source_dir}/${link_target}"
        fi
    done
    cd -P -- "$(dirname -- "$source_path")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR="$(resolve_script_dir)" \
    || { printf '无法定位 VPS Tool 安装目录\n' >&2; exit 1; }
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/config/defaults.conf"
for module in common update preflight firewall user rollback ssh root-login logrotate fail2ban fail2ban-log vnstat bbr verify status menu; do
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/lib/${module}.sh"
done

# 自动生成的私钥仅在用户完成下载和登录确认前临时保留；未完成的 root 配置自动恢复。
cleanup_vps_tool_session() {
    cleanup_update_transaction
    cleanup_pending_root_login
    cleanup_generated_private_key
}
trap cleanup_vps_tool_session EXIT


usage() {
    cat <<EOF_USAGE
${APP_NAME} ${APP_VERSION}

用法：sudo bash vps-init.sh [选项]

选项：
  --interactive       进入交互模式（默认）
  --all               执行完整配置流程
  --status            查看系统状态
  --verify            检查系统配置
  --fail2ban-logs     进入 Fail2ban 日志中心
  --vnstat            进入 vnStat 流量中心
  --enable-root       启用 root SSH 登录
  --rollback          立即执行待处理 SSH 回滚
  --update            检查并安装可用更新
  --no-clear          不清理终端画面
  --help              显示帮助

说明：SSH、Fail2ban、vnStat 和 BBRv3 配置建议在 VPS 控制台可用时执行。
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
    cleanup_retained_update_directories
    local requested_action="${1:---interactive}"
    if [[ "${UPDATE_ENABLED:-yes}" == "yes" \
        && "${VPS_TOOL_SKIP_UPDATE:-0}" != "1" \
        && "$requested_action" != "--update" \
        && "$requested_action" != "--rollback" ]]; then
        auto_update_if_available "$@"
    elif [[ -n "${VPS_TOOL_UPDATED_FROM:-}" ]]; then
        log_success "当前运行版本：v${APP_VERSION}"
    fi
    case "${1:---interactive}" in
        --interactive) main_menu ;;
        --all) run_all ;;
        --status) show_full_status ;;
        --verify) verify_system ;;
        --fail2ban-logs) fail2ban_log_menu ;;
        --vnstat) vnstat_menu ;;
        --enable-root) enable_root_login_interactive ;;
        --rollback) run_ssh_rollback_now ;;
        --update) update_now_interactive ;;
        --no-clear) export VPS_TOOL_NO_CLEAR=1; main_menu ;;
        --help|-h) usage ;;
        *) usage; return 2 ;;
    esac
}

main "$@"
