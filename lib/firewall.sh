#!/usr/bin/env bash

FIREWALL_KIND="none"

firewall_detect() {
    FIREWALL_KIND="none"
    if command_exists ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
        FIREWALL_KIND="ufw"
    elif command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        FIREWALL_KIND="firewalld"
    elif command_exists nft && nft list ruleset 2>/dev/null | grep -qE 'hook input|chain input'; then
        FIREWALL_KIND="nftables"
    fi
}

firewall_allow_ssh_port() {
    local port="$1"
    firewall_detect
    case "$FIREWALL_KIND" in
        ufw)
            ufw allow "${port}/tcp" comment 'vps-tool SSH' >/dev/null
            log_success "UFW 已放行 TCP/${port}"
            ;;
        firewalld)
            firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
            firewall-cmd --reload >/dev/null
            log_success "firewalld 已放行 TCP/${port}"
            ;;
        nftables)
            log_warn "检测到自定义 nftables 规则。脚本不会直接修改规则，请确认 TCP/${port} 已放行"
            confirm "已在 nftables 或云安全组放行 TCP/${port}" "Y" \
                || return 1
            ;;
        none)
            log_warn "未检测到活动的 UFW/firewalld；仍需确认云厂商安全组已放行 TCP/${port}"
            confirm "已确认云安全组允许 TCP/${port}" "Y" || return 1
            ;;
    esac
}

firewall_remove_ssh_port() {
    local port="$1"
    firewall_detect
    case "$FIREWALL_KIND" in
        ufw) ufw --force delete allow "${port}/tcp" >/dev/null 2>&1 || true ;;
        firewalld)
            firewall-cmd --permanent --remove-port="${port}/tcp" >/dev/null 2>&1 || true
            firewall-cmd --reload >/dev/null 2>&1 || true
            ;;
    esac
}
