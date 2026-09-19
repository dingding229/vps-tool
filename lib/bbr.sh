#!/usr/bin/env bash

BBR_STATUS="unknown"

show_bbr_status() {
    ui_title "BBR / TCP 状态"
    printf '  %-26s %s\n' '当前内核' "$(uname -r)"
    printf '  %-26s %s\n' '拥塞控制算法' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
    printf '  %-26s %s\n' '默认队列算法' "$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
    if [[ -d /sys/module/tcp_bbr ]]; then
        printf '  %-26s %s\n' 'tcp_bbr 模块' '已加载'
    else
        printf '  %-26s %s\n' 'tcp_bbr 模块' '未检测到'
    fi
    modinfo tcp_bbr 2>/dev/null | awk -F': ' '/^version:/ {printf "  %-26s %s\n", "BBR 模块版本", $2; found=1} END {if (!found) printf "  %-26s %s\n", "BBR 模块版本", "未知"}'
}

install_bbr_interactive() {
    ui_header
    ui_title "BBRv3 内核配置"
    check_supported_os
    printf '%s注意：BBRv3 会安装自定义内核，完成后通常需要重启。%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s上游项目：%s%s%s\n\n' "$C_DIM" "$C_CYAN" "$BBR_REPOSITORY_URL" "$C_RESET"
    confirm "下载并运行 Actions-bbr-v3 安装器" "N" || { log_warn "已取消 BBRv3 安装"; return 0; }

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

    if ! bash "$installer" 2>&1 | tee -a "$APP_LOG_FILE"; then
        log_error "BBRv3 安装器执行失败，详情见 ${APP_LOG_FILE}"
        rm -rf "$temp_dir"
        return 1
    fi
    rm -rf "$temp_dir"
    trap - INT TERM
    printf 'BBR_INSTALL_REQUESTED=yes\nREBOOT_REQUIRED=yes\nUPDATED_AT=%q\n' \
        "$(date -Is)" > "${APP_STATE_DIR}/bbr.conf"
    chmod 600 "${APP_STATE_DIR}/bbr.conf"
    log_success "BBRv3 安装流程结束；请根据上游安装器提示重启服务器"
}
