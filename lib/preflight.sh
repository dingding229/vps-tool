#!/usr/bin/env bash

OS_ID="unknown"
OS_VERSION="unknown"
OS_PRETTY="Unknown Linux"
OS_ARCH="$(uname -m)"

load_os_release() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release"
    # shellcheck disable=SC1091
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_PRETTY="${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"
    OS_ARCH="$(uname -m)"
}

check_supported_os() {
    load_os_release
    case "$OS_ID" in
        debian)
            [[ "${OS_VERSION%%.*}" =~ ^[0-9]+$ ]] && (( ${OS_VERSION%%.*} >= 12 )) \
                || die "仅支持 Debian 12 及以上版本，当前：${OS_PRETTY}"
            ;;
        ubuntu)
            local major minor
            major="${OS_VERSION%%.*}"
            minor="${OS_VERSION#*.}"; minor="${minor%%.*}"
            [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] \
                || die "无法识别 Ubuntu 版本：${OS_PRETTY}"
            (( major > 24 || (major == 24 && minor >= 4) )) \
                || die "仅支持 Ubuntu 24.04 及以上版本，当前：${OS_PRETTY}"
            ;;
        *) die "仅支持 Debian 12+ 和 Ubuntu 24.04+，当前：${OS_PRETTY}" ;;
    esac

    case "$OS_ARCH" in
        x86_64|aarch64|arm64) ;;
        *) die "不支持的 CPU 架构：${OS_ARCH}，仅支持 x86_64/aarch64" ;;
    esac

    command_exists apt-get || die "未找到 apt-get"
    command_exists systemctl || die "未找到 systemd/systemctl"
}

check_network() {
    if curl -fsSIL --connect-timeout 8 https://github.com >/dev/null 2>&1; then
        log_success "GitHub 网络连接正常"
    else
        log_warn "无法连接 GitHub；Fail2ban 仍可配置，但 BBRv3 下载可能失败"
    fi
}

show_preflight() {
    local order="${1:-01}"
    load_os_release
    ui_section "$order" "运行环境"
    ui_kv "操作系统" "$OS_PRETTY"
    ui_kv "CPU 架构" "$OS_ARCH"
    ui_kv "当前内核" "$(uname -r)"
    ui_kv "虚拟化" "$(systemd-detect-virt 2>/dev/null || printf 'unknown')"
    ui_kv "当前用户" "$(id -un)"
    ui_kv "当前时间" "$(beijing_now) ${APP_TIMEZONE_LABEL:-北京时间}"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ui_kv "SSH 会话" "$(ui_expect yes yes)"
    else
        ui_kv "SSH 会话" "$(ui_expect no yes)"
    fi
}


run_preflight() {
    ui_header
    ui_title "运行环境检查"

    ui_section "01" "系统兼容性"
    check_supported_os
    ui_kv "检测结果" "${C_GREEN}✔ 支持${C_RESET}"
    ui_kv "操作系统" "$OS_PRETTY"
    ui_kv "CPU 架构" "$OS_ARCH"

    ui_section "02" "网络连接"
    check_network

    ui_section "03" "磁盘空间"
    local free_mb
    free_mb="$(df -Pm / | awk 'NR==2 {print $4}')"
    ui_kv "根分区可用" "${free_mb:-未知} MiB"
    if [[ "$free_mb" =~ ^[0-9]+$ ]] && (( free_mb < 1024 )); then
        log_warn "根分区可用空间不足 1 GiB，安装 BBRv3 内核可能失败"
    else
        log_success "磁盘空间检查通过"
    fi
}
