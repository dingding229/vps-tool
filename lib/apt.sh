#!/usr/bin/env bash

APT_STATE_FILE="${APT_STATE_FILE:-${APP_STATE_DIR}/apt.conf}"
APT_UPGRADABLE_COUNT=0
APT_UPGRADABLE_PACKAGES=""

apt_is_supported() {
    command_exists apt-get && command_exists dpkg-query
}

refresh_apt_indexes() {
    apt_is_supported || return 2
    log_info "正在刷新 APT 软件包索引..."
    if ! DEBIAN_FRONTEND=noninteractive LC_ALL=C \
        apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT:-15}" update -y \
        >> "$APP_LOG_FILE" 2>&1; then
        log_warn "APT 软件包索引刷新失败，详情见 ${APP_LOG_FILE}"
        return 1
    fi
    return 0
}

read_apt_upgrade_status() {
    local simulation count packages
    APT_UPGRADABLE_COUNT=0
    APT_UPGRADABLE_PACKAGES=""
    apt_is_supported || return 2

    simulation="$(LC_ALL=C apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null)" || return 1
    count="$(awk '
        /^[0-9]+ upgraded,/ {
            pending=$1
            for (i=2; i<=NF; i++) {
                if ($i == "not" && $(i+1) ~ /^upgraded/) pending += $(i-1)
            }
            print pending
            exit
        }
    ' <<< "$simulation")"
    [[ "$count" =~ ^[0-9]+$ ]] || return 1
    APT_UPGRADABLE_COUNT="$count"
    if (( count > 0 )); then
        packages="$(awk -v limit="${APT_PACKAGE_PREVIEW_LIMIT:-8}" '
            /^Inst / {
                name=$2
                version=""
                for (i=3; i<=NF; i++) {
                    if ($i ~ /^\(/) {version=$i; gsub(/^\(|\)$/, "", version); break}
                }
                print name (version != "" ? " " version : "")
                shown++
                if (shown >= limit) exit
            }
        ' <<< "$simulation")"
        APT_UPGRADABLE_PACKAGES="$packages"
    fi
    return 0
}

write_apt_state() {
    local status="$1" count="${2:-0}" message="${3:-}"
    mkdir -p "$(dirname "$APT_STATE_FILE")"
    cat > "$APT_STATE_FILE" <<EOF_STATE
STATUS=${status}
UPGRADABLE_COUNT=${count}
CHECKED_AT=$(beijing_iso)
REBOOT_REQUIRED=$([[ -f /var/run/reboot-required ]] && printf yes || printf no)
MESSAGE=${message}
EOF_STATE
    chmod 600 "$APT_STATE_FILE"
}

print_apt_package_preview() {
    local package shown=0
    [[ -n "$APT_UPGRADABLE_PACKAGES" ]] || return 0
    ui_subtitle "可升级软件包"
    while IFS= read -r package; do
        [[ -n "$package" ]] || continue
        printf '  %s●%s %s\n' "$C_YELLOW" "$C_RESET" "$package"
        shown=$((shown + 1))
    done <<< "$APT_UPGRADABLE_PACKAGES"
    if (( APT_UPGRADABLE_COUNT > shown )); then
        printf '  %s其余 %d 个软件包未展开显示%s\n' \
            "$C_DIM" "$((APT_UPGRADABLE_COUNT - shown))" "$C_RESET"
    fi
}

upgrade_apt_packages() {
    log_info "正在升级 APT 软件包，请勿中断当前操作..."
    if ! DEBIAN_FRONTEND=noninteractive LC_ALL=C \
        apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT:-15}" \
        upgrade --with-new-pkgs -y >> "$APP_LOG_FILE" 2>&1; then
        write_apt_state "upgrade_failed" "$APT_UPGRADABLE_COUNT" "软件包升级失败"
        log_error "APT 软件包升级失败，详情见 ${APP_LOG_FILE}"
        return 1
    fi

    if ! read_apt_upgrade_status; then
        write_apt_state "check_failed" 0 "升级后状态检查失败"
        log_warn "软件包升级完成，但无法读取最新状态"
        return 0
    fi

    if (( APT_UPGRADABLE_COUNT == 0 )); then
        write_apt_state "current" 0 "软件包均为最新版本"
        log_success "APT 软件包已升级到最新版本"
    else
        write_apt_state "updates_remaining" "$APT_UPGRADABLE_COUNT" "仍有软件包需要单独处理"
        log_warn "升级完成，但仍有 ${APT_UPGRADABLE_COUNT} 个软件包未升级"
    fi
    if [[ -f /var/run/reboot-required ]]; then
        log_warn "系统更新后需要重启服务器"
    fi
}

apt_startup_should_prompt() {
    local action="${1:---interactive}"
    [[ -t 0 && -t 1 ]] || return 1
    case "$action" in
        --status|--verify|--rollback|--update|--apt) return 1 ;;
        *) return 0 ;;
    esac
}

check_apt_before_startup() {
    local action="${1:---interactive}" refresh_result=0
    apt_is_supported || return 0

    refresh_apt_indexes || refresh_result=$?
    if (( refresh_result != 0 )); then
        write_apt_state "index_failed" 0 "软件包索引刷新失败"
        return 0
    fi
    if ! read_apt_upgrade_status; then
        write_apt_state "check_failed" 0 "无法读取软件包状态"
        log_warn "无法判断 APT 软件包是否为最新版本"
        return 0
    fi

    if (( APT_UPGRADABLE_COUNT == 0 )); then
        write_apt_state "current" 0 "软件包均为最新版本"
        log_success "APT 软件包索引和已安装软件包均为最新"
        return 0
    fi

    write_apt_state "updates_available" "$APT_UPGRADABLE_COUNT" "存在可升级软件包"
    log_warn "检测到 ${APT_UPGRADABLE_COUNT} 个可升级的 APT 软件包"
    if apt_startup_should_prompt "$action"; then
        print_apt_package_preview
        printf '\n'
        if confirm "是否现在升级这些软件包" "Y"; then
            upgrade_apt_packages || return 0
        else
            log_warn "已跳过软件包升级"
        fi
    fi
}

manage_apt_interactive() {
    ui_header
    ui_title "APT 软件包更新"
    ui_section "01" "软件包索引"

    local refresh_result=0
    refresh_apt_indexes || refresh_result=$?
    if (( refresh_result != 0 )); then
        write_apt_state "index_failed" 0 "软件包索引刷新失败"
        return 1
    fi
    ui_kv "索引状态" "${C_GREEN}✔ 已刷新${C_RESET}"

    ui_section "02" "可用更新"
    if ! read_apt_upgrade_status; then
        write_apt_state "check_failed" 0 "无法读取软件包状态"
        log_error "无法读取 APT 软件包状态"
        return 1
    fi
    ui_kv "可升级数量" "$APT_UPGRADABLE_COUNT"
    if (( APT_UPGRADABLE_COUNT == 0 )); then
        write_apt_state "current" 0 "软件包均为最新版本"
        log_success "APT 软件包均为最新版本"
        return 0
    fi

    write_apt_state "updates_available" "$APT_UPGRADABLE_COUNT" "存在可升级软件包"
    print_apt_package_preview
    printf '\n'
    confirm "是否立即升级 APT 软件包" "Y" || { log_warn "已取消升级"; return 0; }

    ui_section "03" "执行升级"
    upgrade_apt_packages
}

print_apt_status() {
    local status="unknown" count="未知" checked="尚未检查" reboot="no"
    if [[ -r "$APT_STATE_FILE" ]]; then
        status="$(awk -F= '$1=="STATUS" {print substr($0, index($0, "=") + 1); exit}' "$APT_STATE_FILE")"
        count="$(awk -F= '$1=="UPGRADABLE_COUNT" {print substr($0, index($0, "=") + 1); exit}' "$APT_STATE_FILE")"
        checked="$(awk -F= '$1=="CHECKED_AT" {print substr($0, index($0, "=") + 1); exit}' "$APT_STATE_FILE")"
        reboot="$(awk -F= '$1=="REBOOT_REQUIRED" {print substr($0, index($0, "=") + 1); exit}' "$APT_STATE_FILE")"
    fi
    case "$status" in
        current) status="${C_GREEN}✔ 已是最新版本${C_RESET}" ;;
        updates_available|updates_remaining) status="${C_YELLOW}▲ 有可用更新${C_RESET}" ;;
        index_failed|check_failed|upgrade_failed) status="${C_RED}✖ 检查或升级失败${C_RESET}" ;;
        *) status="${C_DIM}尚未检查${C_RESET}" ;;
    esac
    ui_kv "APT 状态" "$status"
    ui_kv "可升级数量" "$count"
    if [[ "$checked" == "尚未检查" ]]; then
        ui_kv "检查时间" "$checked"
    else
        ui_kv "检查时间" "${checked} ${APP_TIMEZONE_LABEL:-北京时间}"
    fi
    if [[ "$reboot" == "yes" || -f /var/run/reboot-required ]]; then
        ui_kv "系统重启" "${C_YELLOW}▲ 需要重启${C_RESET}"
    else
        ui_kv "系统重启" "${C_GREEN}✔ 暂不需要${C_RESET}"
    fi
}
