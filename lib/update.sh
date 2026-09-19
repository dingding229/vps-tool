#!/usr/bin/env bash

UPDATE_STATE_FILE="${UPDATE_STATE_FILE:-${APP_STATE_DIR}/update.conf}"
UPDATE_AVAILABLE_VERSION=""

normalize_app_version() {
    local version="${1#v}"
    [[ "$version" =~ ^[0-9]+([.][0-9]+){2}$ ]] || return 1
    printf '%s' "$version"
}

version_is_newer() {
    local current latest
    current="$(normalize_app_version "$1")" || return 1
    latest="$(normalize_app_version "$2")" || return 1
    awk -v current="$current" -v latest="$latest" 'BEGIN {
        split(current, c, "."); split(latest, l, ".")
        for (i = 1; i <= 3; i++) {
            if ((l[i] + 0) > (c[i] + 0)) exit 0
            if ((l[i] + 0) < (c[i] + 0)) exit 1
        }
        exit 1
    }'
}

update_check_url() {
    printf 'https://raw.githubusercontent.com/%s/%s/%s/config/defaults.conf' \
        "$UPDATE_REPO_OWNER" "$UPDATE_REPO_NAME" "$UPDATE_REPO_BRANCH"
}

update_archive_url() {
    printf 'https://github.com/%s/%s/archive/refs/heads/%s.tar.gz' \
        "$UPDATE_REPO_OWNER" "$UPDATE_REPO_NAME" "$UPDATE_REPO_BRANCH"
}

read_remote_app_version() {
    local content version
    command_exists curl || return 1
    content="$(curl --fail --silent --show-error --location \
        --connect-timeout "${UPDATE_CONNECT_TIMEOUT:-8}" \
        --max-time "${UPDATE_MAX_TIME:-20}" \
        "$(update_check_url)?time=$(beijing_date '+%s')" 2>/dev/null)" || return 1
    version="$(sed -n 's/^APP_VERSION="\([^"]*\)".*/\1/p' <<< "$content" | head -n 1)"
    normalize_app_version "$version"
}

write_update_state() {
    local status="$1" latest="${2:-${APP_VERSION}}" message="${3:-}" current="${4:-${APP_VERSION}}"
    mkdir -p "$(dirname "$UPDATE_STATE_FILE")"
    cat > "$UPDATE_STATE_FILE" <<EOF_STATE
STATUS=${status}
CURRENT_VERSION=${current}
LATEST_VERSION=${latest}
CHECKED_AT=$(beijing_iso)
MESSAGE=${message}
EOF_STATE
    chmod 600 "$UPDATE_STATE_FILE"
}

is_managed_installation() {
    [[ -n "${SCRIPT_DIR:-}" && -f "${SCRIPT_DIR}/vps-init.sh" ]] || return 1
    [[ ! -d "${SCRIPT_DIR}/.git" ]]
}

install_remote_update() {
    local latest="$1" parent base temp_dir archive source_dir backup_dir archive_version
    parent="$(dirname "$SCRIPT_DIR")"
    base="$(basename "$SCRIPT_DIR")"
    temp_dir="$(mktemp -d "${parent}/.${base}-update.XXXXXX")" \
        || { log_warn "无法创建更新目录，继续使用当前版本"; return 1; }
    archive="${temp_dir}/source.tar.gz"

    if ! curl --fail --silent --show-error --location \
        --connect-timeout "${UPDATE_CONNECT_TIMEOUT:-8}" \
        --max-time "${UPDATE_DOWNLOAD_MAX_TIME:-120}" \
        --retry 2 --output "$archive" "$(update_archive_url)" 2>> "$APP_LOG_FILE"; then
        log_warn "更新包下载失败，继续使用当前版本"
        rm -rf "$temp_dir"
        return 1
    fi

    if ! tar -xzf "$archive" --no-same-owner --no-same-permissions \
        -C "$temp_dir" >> "$APP_LOG_FILE" 2>&1; then
        log_warn "更新包无法解压，继续使用当前版本"
        rm -rf "$temp_dir"
        return 1
    fi
    source_dir="$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' | head -n 1)"
    if [[ -z "$source_dir" \
        || ! -f "${source_dir}/vps-init.sh" \
        || ! -f "${source_dir}/install.sh" \
        || ! -f "${source_dir}/config/defaults.conf" \
        || ! -f "${source_dir}/lib/common.sh" \
        || ! -f "${source_dir}/lib/update.sh" \
        || ! -d "${source_dir}/scripts" ]]; then
        log_warn "更新包文件不完整，继续使用当前版本"
        rm -rf "$temp_dir"
        return 1
    fi

    archive_version="$(sed -n 's/^APP_VERSION="\([^"]*\)".*/\1/p' "${source_dir}/config/defaults.conf" | head -n 1)"
    if [[ "$archive_version" != "$latest" ]]; then
        log_warn "更新包版本不一致，继续使用当前版本"
        rm -rf "$temp_dir"
        return 1
    fi
    if ! find "$source_dir" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n; then
        log_warn "更新包脚本检查未通过，继续使用当前版本"
        rm -rf "$temp_dir"
        return 1
    fi

    chmod 700 "${source_dir}/vps-init.sh" "${source_dir}/install.sh"
    find "${source_dir}/scripts" -type f -name '*.sh' -exec chmod 700 {} +
    backup_dir="${SCRIPT_DIR}.backup.$(beijing_compact)"
    [[ ! -e "$backup_dir" ]] || backup_dir="${backup_dir}.$$"

    if ! mv "$SCRIPT_DIR" "$backup_dir"; then
        log_warn "当前程序无法备份，继续使用当前版本"
        rm -rf "$temp_dir"
        return 1
    fi
    if ! mv "$source_dir" "$SCRIPT_DIR"; then
        mv "$backup_dir" "$SCRIPT_DIR" 2>/dev/null || true
        log_error "更新安装失败，已恢复当前版本"
        rm -rf "$temp_dir"
        return 1
    fi
    rm -rf "$temp_dir"

    write_update_state "updated" "$latest" "自动更新完成" "$latest"
    log_success "VPS Tool 已从 v${APP_VERSION} 更新到 v${latest}"
    log_info "旧版本已备份到 ${backup_dir}"
    return 0
}

check_for_updates() {
    local mode="${1:-auto}" latest
    UPDATE_AVAILABLE_VERSION=""

    if [[ "${VPS_TOOL_DISABLE_AUTO_UPDATE:-0}" == "1" && "$mode" == "auto" ]]; then
        return 0
    fi
    if ! is_managed_installation; then
        [[ "$mode" == "manual" ]] && log_warn "当前安装目录不支持内置更新"
        return 0
    fi

    if [[ "$mode" == "manual" ]]; then
        log_info "正在检查 VPS Tool 更新..."
    fi
    latest="$(read_remote_app_version)" || {
        write_update_state "unavailable" "$APP_VERSION" "暂时无法连接更新服务"
        [[ "$mode" == "manual" ]] && log_warn "暂时无法检查更新"
        return 1
    }

    if version_is_newer "$APP_VERSION" "$latest"; then
        UPDATE_AVAILABLE_VERSION="$latest"
        write_update_state "available" "$latest" "发现新版本"
        return 10
    fi

    write_update_state "current" "$latest" "当前已是最新版本"
    [[ "$mode" == "manual" ]] && log_success "当前已是最新版本 v${APP_VERSION}"
    return 0
}

auto_update_if_available() {
    local result=0 latest
    check_for_updates auto || result=$?
    [[ "$result" == "10" ]] || return 0
    latest="$UPDATE_AVAILABLE_VERSION"
    log_info "发现 VPS Tool 新版本 v${latest}，正在自动更新..."
    install_remote_update "$latest" || return 0

    export VPS_TOOL_SKIP_UPDATE=1
    export VPS_TOOL_UPDATED_FROM="$APP_VERSION"
    exec bash "${SCRIPT_DIR}/vps-init.sh" "$@"
}

update_now_interactive() {
    ui_header
    ui_title "VPS Tool 更新"
    ui_section "01" "版本信息"
    ui_kv "当前版本" "v${APP_VERSION}"
    ui_kv "更新来源" "GitHub ${UPDATE_REPO_OWNER}/${UPDATE_REPO_NAME}"
    ui_kv "更新分支" "$UPDATE_REPO_BRANCH"

    local result=0 latest
    printf '\n'
    check_for_updates manual || result=$?
    case "$result" in
        0) return 0 ;;
        10)
            latest="$UPDATE_AVAILABLE_VERSION"
            ui_section "02" "可用更新"
            ui_kv "最新版本" "${C_GREEN}v${latest}${C_RESET}"
            ui_kv "当前版本" "v${APP_VERSION}"
            printf '\n'
            confirm "是否立即更新" "Y" || { log_warn "已取消更新"; return 0; }
            if install_remote_update "$latest"; then
                export VPS_TOOL_SKIP_UPDATE=1
                export VPS_TOOL_UPDATED_FROM="$APP_VERSION"
                exec bash "${SCRIPT_DIR}/vps-init.sh" --interactive
            fi
            return 1
            ;;
        *) return 1 ;;
    esac
}

print_update_status() {
    local status="未知" latest="$APP_VERSION" checked="尚未检查"
    if [[ -r "$UPDATE_STATE_FILE" ]]; then
        status="$(awk -F= '$1=="STATUS" {print substr($0, index($0, "=") + 1); exit}' "$UPDATE_STATE_FILE")"
        latest="$(awk -F= '$1=="LATEST_VERSION" {print substr($0, index($0, "=") + 1); exit}' "$UPDATE_STATE_FILE")"
        checked="$(awk -F= '$1=="CHECKED_AT" {print substr($0, index($0, "=") + 1); exit}' "$UPDATE_STATE_FILE")"
    fi
    case "$status" in
        current|updated) status="${C_GREEN}✔ 已是最新版本${C_RESET}" ;;
        available) status="${C_YELLOW}▲ 有可用更新${C_RESET}" ;;
        unavailable) status="${C_YELLOW}▲ 暂时无法检查${C_RESET}" ;;
        *) status="${C_DIM}尚未检查${C_RESET}" ;;
    esac
    ui_kv "当前版本" "v${APP_VERSION}"
    if [[ "${UPDATE_ENABLED:-yes}" == "yes" ]]; then
        ui_kv "自动更新" "${C_GREEN}● 已启用${C_RESET}"
    else
        ui_kv "自动更新" "${C_YELLOW}● 已关闭${C_RESET}"
    fi
    ui_kv "更新状态" "$status"
    ui_kv "远程版本" "v${latest:-$APP_VERSION}"
    if [[ "$checked" == "尚未检查" ]]; then
        ui_kv "检查时间" "$checked"
    else
        ui_kv "检查时间" "${checked} ${APP_TIMEZONE_LABEL:-北京时间}"
    fi
}
