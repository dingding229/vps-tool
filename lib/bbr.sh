#!/usr/bin/env bash

BBR_STATUS="unknown"

show_bbr_status() {
    local kernel congestion qdisc module_state module_version
    kernel="$(uname -r)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
    if [[ -d /sys/module/tcp_bbr ]]; then module_state="loaded"; else module_state="missing"; fi
    module_version="$(modinfo tcp_bbr 2>/dev/null | awk -F': ' '/^version:/ {print $2; exit}')"

    ui_kv "当前内核" "$kernel"
    ui_kv "拥塞控制算法" "$congestion"
    ui_kv "默认队列算法" "$qdisc"
    if [[ "$module_state" == "loaded" ]]; then
        ui_kv "tcp_bbr 模块" "${C_GREEN}✔ 已加载${C_RESET}"
    else
        ui_kv "tcp_bbr 模块" "${C_YELLOW}▲ 未检测到${C_RESET}"
    fi
    ui_kv "BBR 模块版本" "${module_version:-未知}"
}


install_bbr_interactive() {
    ui_header
    ui_title "BBRv3 内核配置"
    check_supported_os
    ui_section "01" "安装说明"
    ui_kv "当前内核" "$(uname -r)"
    ui_kv "上游项目" "${C_CYAN}${BBR_REPOSITORY_URL}${C_RESET}"
    ui_kv "安装影响" "${C_YELLOW}安装自定义内核，完成后通常需要重启${C_RESET}"
    printf '\n'
    confirm "下载并运行 Actions-bbr-v3 安装器" "Y" || { log_warn "已取消 BBRv3 安装"; return 0; }

    command_exists curl || { log_error "未找到 curl"; return 1; }
    local temp_dir installer
    temp_dir="$(mktemp -d)"
    installer="${temp_dir}/actions-bbr-v3-install.sh"
    trap 'rm -rf "$temp_dir"; exit 130' INT TERM

    log_info "正在下载 BBRv3 安装器..."
    curl --fail --silent --show-error --location --connect-timeout 15 \
        --output "$installer" "$BBR_INSTALLER_URL" \
        || { log_error "BBRv3 安装器下载失败"; rm -rf "$temp_dir"; return 1; }
    [[ -s "$installer" ]] || { log_error "下载的安装器为空"; rm -rf "$temp_dir"; return 1; }
    chmod 700 "$installer"
    if command_exists sha256sum; then
        log_info "安装器 SHA256：$(sha256sum "$installer" | awk '{print $1}')"
    fi
    log_success "安装器已下载，日志将写入 ${APP_LOG_FILE}"

    if ! TZ="${APP_TIMEZONE:-Asia/Shanghai}" bash "$installer" 2>&1 | tee -a "$APP_LOG_FILE"; then
        log_error "BBRv3 安装器执行失败，详情见 ${APP_LOG_FILE}"
        rm -rf "$temp_dir"
        return 1
    fi
    rm -rf "$temp_dir"
    trap - INT TERM
    printf 'BBR_INSTALL_REQUESTED=yes\nREBOOT_REQUIRED=yes\nUPDATED_AT=%q\n' \
        "$(beijing_iso)" > "${APP_STATE_DIR}/bbr.conf"
    chmod 600 "${APP_STATE_DIR}/bbr.conf"
    log_success "BBRv3 安装流程结束；请根据上游安装器提示重启服务器"
}
