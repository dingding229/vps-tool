#!/usr/bin/env bash

BBR_REBOOT_SCHEDULED="no"
BBR_REBOOT_REQUIRED="no"
BBR_STATE_FILE="${BBR_STATE_FILE:-${APP_STATE_DIR}/bbr.conf}"
BBR_RESUME_UNIT="${BBR_RESUME_UNIT:-vps-tool-bbr-resume.service}"
BBR_RESUME_UNIT_FILE="${BBR_RESUME_UNIT_FILE:-/etc/systemd/system/${BBR_RESUME_UNIT}}"
BBR_SYSCTL_FILE="${BBR_SYSCTL_FILE:-/etc/sysctl.d/99-vps-tool-bbr.conf}"

current_boot_id() {
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        command cat /proc/sys/kernel/random/boot_id
    else
        printf 'unknown'
    fi
}

bbr_module_version() {
    command_exists modinfo || return 0
    modinfo tcp_bbr 2>/dev/null | awk -F': ' '/^version:/ {print $2; exit}' || true
}

read_bbr_state_value() {
    local key="$1"
    [[ -r "$BBR_STATE_FILE" ]] || return 1
    awk -F= -v key="$key" '$1==key {print substr($0, index($0, "=") + 1); exit}' "$BBR_STATE_FILE"
}

write_bbr_state() {
    local status="$1" reboot_required="$2" target_kernel="${3:-unknown}"
    local original_boot_id="${4:-$(current_boot_id)}" original_kernel="${5:-$(uname -r)}"
    local message="${6:-}" notified="${7:-no}"
    local current_kernel module_version congestion qdisc temp_file
    current_kernel="$(uname -r)"
    module_version="$(bbr_module_version)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
    mkdir -p "$(dirname "$BBR_STATE_FILE")"
    temp_file="${BBR_STATE_FILE}.tmp.$$"
    cat > "$temp_file" <<EOF_STATE
STATUS=${status}
REBOOT_REQUIRED=${reboot_required}
TARGET_KERNEL=${target_kernel}
ORIGINAL_BOOT_ID=${original_boot_id}
ORIGINAL_KERNEL=${original_kernel}
CURRENT_BOOT_ID=$(current_boot_id)
CURRENT_KERNEL=${current_kernel}
BBR_VERSION=${module_version:-unknown}
CONGESTION_CONTROL=${congestion:-unknown}
DEFAULT_QDISC=${qdisc:-unknown}
UPDATED_AT=$(beijing_iso)
MESSAGE=${message}
NOTIFIED=${notified}
EOF_STATE
    chmod 600 "$temp_file"
    mv "$temp_file" "$BBR_STATE_FILE"
}

mark_bbr_state_notified() {
    local temp_file
    [[ -r "$BBR_STATE_FILE" ]] || return 0
    temp_file="${BBR_STATE_FILE}.tmp.$$"
    awk '
        BEGIN {updated=0}
        /^NOTIFIED=/ {print "NOTIFIED=yes"; updated=1; next}
        {print}
        END {if (!updated) print "NOTIFIED=yes"}
    ' "$BBR_STATE_FILE" > "$temp_file"
    chmod 600 "$temp_file"
    mv "$temp_file" "$BBR_STATE_FILE"
}

latest_installed_bbr_kernel() {
    local package_kernels="" boot_kernels="" image kernel
    if command_exists dpkg-query; then
        # shellcheck disable=SC2016
        package_kernels="$(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package}\n' 2>/dev/null \
            | awk '$1 ~ /^ii/ && $2 ~ /^linux-image-.*joeyblog-bbrv3/ {
                name=$2
                sub(/:.*/, "", name)
                sub(/^linux-image-/, "", name)
                print name
            }' || true)"
    fi
    for image in /boot/vmlinuz-*-joeyblog-bbrv3*; do
        [[ -e "$image" ]] || continue
        kernel="${image##*/vmlinuz-}"
        boot_kernels+="${kernel}"$'\n'
    done
    printf '%s\n%s' "$package_kernels" "$boot_kernels" \
        | awk 'NF && !seen[$0]++' | sort -V | tail -n 1
}

bbr_runtime_active() {
    local version congestion qdisc
    version="$(bbr_module_version)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    [[ "$version" == "3" && "$congestion" == "bbr" && "$qdisc" == "fq" ]]
}

bbr_failure_reason() {
    local kernel version congestion qdisc
    kernel="$(uname -r)"
    version="$(bbr_module_version)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"
    if [[ "$kernel" != *joeyblog-bbrv3* ]]; then
        printf 'CURRENT_KERNEL_NOT_BBRV3'
    elif [[ "$version" != "3" ]]; then
        printf 'BBR_MODULE_NOT_READY'
    elif [[ "$congestion" != "bbr" ]]; then
        printf 'CONGESTION_CONTROL_NOT_READY'
    elif [[ "$qdisc" != "fq" ]]; then
        printf 'DEFAULT_QDISC_NOT_READY'
    else
        printf 'UNKNOWN_POST_REBOOT_FAILURE'
    fi
}

reconcile_bbr_state() {
    local status target original_boot original_kernel current_kernel
    [[ -r "$BBR_STATE_FILE" ]] || return 1
    status="$(read_bbr_state_value STATUS 2>/dev/null || true)"
    case "$status" in
        installing|pending_reboot|verification_failed) ;;
        *) return 1 ;;
    esac
    current_kernel="$(uname -r)"
    [[ "$current_kernel" == *joeyblog-bbrv3* ]] || return 1
    bbr_runtime_active || return 1

    target="$(read_bbr_state_value TARGET_KERNEL 2>/dev/null || true)"
    original_boot="$(read_bbr_state_value ORIGINAL_BOOT_ID 2>/dev/null || true)"
    original_kernel="$(read_bbr_state_value ORIGINAL_KERNEL 2>/dev/null || true)"
    [[ -n "$target" && "$target" != "unknown" ]] || target="$current_kernel"
    write_bbr_state "active" "no" "$target" "$original_boot" "$original_kernel" \
        "BBRv3_RUNTIME_RECONCILED" "no"
    remove_bbr_resume_service
    return 0
}

show_bbr_status() {
    local kernel congestion qdisc module_state module_version workflow target reboot_required message
    reconcile_bbr_state >/dev/null 2>&1 || true
    kernel="$(uname -r)"
    congestion="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || printf 'unknown')"
    qdisc="$(sysctl -n net.core.default_qdisc 2>/dev/null || printf 'unknown')"
    if [[ -d /sys/module/tcp_bbr ]]; then module_state="loaded"; else module_state="missing"; fi
    module_version="$(bbr_module_version)"

    ui_kv "当前内核" "$kernel"
    ui_kv "拥塞控制算法" "$congestion"
    ui_kv "默认队列算法" "$qdisc"
    if [[ "$module_state" == "loaded" ]]; then
        ui_kv "tcp_bbr 模块" "${C_GREEN}✔ 已加载${C_RESET}"
    else
        ui_kv "tcp_bbr 模块" "${C_YELLOW}▲ 未检测到${C_RESET}"
    fi
    ui_kv "BBR 模块版本" "${module_version:-未知}"

    workflow="$(read_bbr_state_value STATUS 2>/dev/null || true)"
    target="$(read_bbr_state_value TARGET_KERNEL 2>/dev/null || true)"
    reboot_required="$(read_bbr_state_value REBOOT_REQUIRED 2>/dev/null || true)"
    message="$(read_bbr_state_value MESSAGE 2>/dev/null || true)"
    case "$workflow" in
        installing) ui_kv "安装流程" "${C_YELLOW}● 内核安装中${C_RESET}" ;;
        pending_reboot) ui_kv "安装流程" "${C_YELLOW}▲ 等待重启并自动验证${C_RESET}" ;;
        active) ui_kv "安装流程" "${C_GREEN}✔ 重启后验证通过${C_RESET}" ;;
        verification_failed)
            ui_kv "安装流程" "${C_RED}✖ 重启后验证失败${C_RESET}"
            case "$message" in
                CURRENT_KERNEL_NOT_BBRV3) ui_kv "失败原因" "当前未进入目标 BBRv3 内核" ;;
                BBR_MODULE_NOT_READY) ui_kv "失败原因" "BBR v3 模块尚未就绪" ;;
                CONGESTION_CONTROL_NOT_READY) ui_kv "失败原因" "拥塞控制算法尚未切换为 bbr" ;;
                DEFAULT_QDISC_NOT_READY) ui_kv "失败原因" "默认队列算法尚未切换为 fq" ;;
                *) ui_kv "失败原因" "开机检查时运行状态尚未就绪" ;;
            esac
            ;;
        installer_failed) ui_kv "安装流程" "${C_RED}✖ 上游安装器执行失败${C_RESET}" ;;
        no_change) ui_kv "安装流程" "${C_DIM}未检测到新的内核安装${C_RESET}" ;;
    esac
    [[ -n "$target" && "$target" != "unknown" ]] && ui_kv "目标内核" "$target"
    if [[ "$reboot_required" == "yes" ]]; then
        ui_kv "重启状态" "${C_YELLOW}▲ 需要重启${C_RESET}"
    fi
}

setup_bbr_resume_service() {
    local entry escaped_entry temp_unit
    entry="${SCRIPT_DIR}/vps-init.sh"
    [[ -f "$entry" ]] || return 1
    escaped_entry="${entry//\\/\\\\}"
    escaped_entry="${escaped_entry//\"/\\\"}"
    mkdir -p "$(dirname "$BBR_RESUME_UNIT_FILE")"
    temp_unit="${BBR_RESUME_UNIT_FILE}.tmp.$$"
    cat > "$temp_unit" <<EOF_UNIT
[Unit]
Description=VPS Tool BBRv3 post-reboot verification
Wants=network-online.target
After=network-online.target systemd-modules-load.service systemd-sysctl.service
ConditionPathExists=${BBR_STATE_FILE}

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/bin/bash "${escaped_entry}" --bbr-resume

[Install]
WantedBy=multi-user.target
EOF_UNIT
    chmod 644 "$temp_unit"
    mv "$temp_unit" "$BBR_RESUME_UNIT_FILE"
    systemctl daemon-reload >> "$APP_LOG_FILE" 2>&1 || return 1
    systemctl enable "$BBR_RESUME_UNIT" >> "$APP_LOG_FILE" 2>&1 || return 1
}

remove_bbr_resume_service() {
    systemctl disable "$BBR_RESUME_UNIT" >> "$APP_LOG_FILE" 2>&1 || true
    rm -f "$BBR_RESUME_UNIT_FILE"
    systemctl daemon-reload >> "$APP_LOG_FILE" 2>&1 || true
}

prepare_bbr_installer_reboot_handoff() {
    local installer="$1" temp_file
    temp_file="${installer}.managed-reboot"
    if awk '
        /是否立即重启/ && /echo/ {
            match($0, /^[[:space:]]*/)
            indent=substr($0, RSTART, RLENGTH)
            print indent "echo \"内核安装完成，重启将由 VPS Tool 统一处理。\""
            next
        }
        /请记得稍后手动重启/ && /echo/ {
            match($0, /^[[:space:]]*/)
            indent=substr($0, RSTART, RLENGTH)
            print indent "echo \"上游内核安装步骤完成，正在返回 VPS Tool。\""
            next
        }
        /^[[:space:]]*read[[:space:]]+-r[[:space:]]+REBOOT_NOW[[:space:]]*$/ {
            sub(/read[[:space:]]+-r[[:space:]]+REBOOT_NOW/, "REBOOT_NOW=\"n\"")
            changed=1
        }
        {print}
        END {if (!changed) exit 3}
    ' "$installer" > "$temp_file"; then
        chmod --reference="$installer" "$temp_file" 2>/dev/null || chmod 700 "$temp_file"
        mv "$temp_file" "$installer"
        return 0
    fi
    rm -f "$temp_file"
    return 1
}

create_bbr_reboot_guard() {
    local guard_dir="$1" marker="$2" command_name real_command
    mkdir -p "$guard_dir"
    for command_name in reboot shutdown poweroff halt; do
        cat > "${guard_dir}/${command_name}" <<'EOF_GUARD'
#!/usr/bin/env bash
set -u
: > "${BBR_REBOOT_MARKER:?}"
printf '\n[VPS Tool] 已接管重启请求，将在保存恢复状态后统一重启。\n'
exit 0
EOF_GUARD
        chmod 700 "${guard_dir}/${command_name}"
    done

    real_command="$(command -v systemctl)"
    cat > "${guard_dir}/systemctl" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -u
for argument in "$@"; do
    case "$argument" in
        reboot|poweroff|halt)
            : > "${BBR_REBOOT_MARKER:?}"
            printf '\n[VPS Tool] 已接管重启请求，将在保存恢复状态后统一重启。\n'
            exit 0
            ;;
    esac
done
exec "${BBR_REAL_SYSTEMCTL:?}" "$@"
EOF_SYSTEMCTL
    chmod 700 "${guard_dir}/systemctl"

    cat > "${guard_dir}/sudo" <<'EOF_SUDO'
#!/usr/bin/env bash
set -u
if (( $# == 0 )); then exit 0; fi
exec "$@"
EOF_SUDO
    chmod 700 "${guard_dir}/sudo"
    printf '%s' "$real_command" > "${guard_dir}/.real-systemctl"
}

run_bbr_installer_guarded() {
    local installer="$1" temp_dir="$2" session_log="$3"
    local guard_dir="${temp_dir}/reboot-guard" marker="${temp_dir}/reboot-requested"
    local real_systemctl
    create_bbr_reboot_guard "$guard_dir" "$marker"
    real_systemctl="$(cat "${guard_dir}/.real-systemctl")"
    BBRV3_SKIP_QUICK_COMMAND=1 \
    BBR_REBOOT_MARKER="$marker" \
    BBR_REAL_SYSTEMCTL="$real_systemctl" \
    PATH="${guard_dir}:$PATH" \
    TZ="${APP_TIMEZONE:-Asia/Shanghai}" \
        bash "$installer" 2>&1 | tee -a "$APP_LOG_FILE" | tee "$session_log"
    local installer_status="${PIPESTATUS[0]}" app_log_status="${PIPESTATUS[1]}" session_log_status="${PIPESTATUS[2]}"
    (( installer_status == 0 && app_log_status == 0 && session_log_status == 0 ))
}

persist_bbr_runtime_defaults() {
    if command_exists modprobe; then
        modprobe tcp_bbr >> "$APP_LOG_FILE" 2>&1 || true
        modprobe sch_fq >> "$APP_LOG_FILE" 2>&1 || true
    fi
    cat > "$BBR_SYSCTL_FILE" <<'EOF_SYSCTL'
# Managed by VPS Tool after BBRv3 kernel activation
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_SYSCTL
    chmod 644 "$BBR_SYSCTL_FILE"
    sysctl -p "$BBR_SYSCTL_FILE" >> "$APP_LOG_FILE" 2>&1
}

resume_bbr_after_reboot() {
    local status original_boot original_kernel target current_boot current_kernel
    local attempts delay attempt reason
    reconcile_bbr_state && return 0

    status="$(read_bbr_state_value STATUS 2>/dev/null || true)"
    case "$status" in
        installing|pending_reboot) ;;
        *)
            [[ -e "$BBR_RESUME_UNIT_FILE" ]] && remove_bbr_resume_service
            return 0
            ;;
    esac

    original_boot="$(read_bbr_state_value ORIGINAL_BOOT_ID 2>/dev/null || true)"
    original_kernel="$(read_bbr_state_value ORIGINAL_KERNEL 2>/dev/null || true)"
    target="$(read_bbr_state_value TARGET_KERNEL 2>/dev/null || true)"
    current_boot="$(current_boot_id)"
    current_kernel="$(uname -r)"
    if [[ -n "$original_boot" && "$original_boot" == "$current_boot" ]]; then
        return 0
    fi

    attempts="${BBR_RESUME_RETRIES:-6}"
    delay="${BBR_RESUME_RETRY_DELAY:-5}"
    log_info "正在执行 BBRv3 重启后自动恢复检查..."
    if [[ "$current_kernel" == *joeyblog-bbrv3* ]]; then
        for ((attempt=1; attempt<=attempts; attempt++)); do
            persist_bbr_runtime_defaults || true
            if bbr_runtime_active; then
                write_bbr_state "active" "no" "$target" "$original_boot" "$original_kernel" \
                    "BBRv3_REBOOT_VERIFIED" "no"
                log_success "BBRv3 已在新内核 ${current_kernel} 上启用"
                remove_bbr_resume_service
                return 0
            fi
            if (( attempt < attempts )); then
                log_warn "BBRv3 运行状态尚未就绪，${delay} 秒后重试（${attempt}/${attempts}）"
                sleep "$delay"
            fi
        done
    fi

    reason="$(bbr_failure_reason)"
    write_bbr_state "verification_failed" "no" "$target" "$original_boot" "$original_kernel" \
        "$reason" "no"
    log_error "BBRv3 重启后检查未通过，当前内核：${current_kernel}，原因：${reason}"
    remove_bbr_resume_service
    return 1
}

notify_bbr_resume_result() {
    local status notified kernel version congestion qdisc
    [[ -r "$BBR_STATE_FILE" ]] || return 0
    status="$(read_bbr_state_value STATUS 2>/dev/null || true)"
    notified="$(read_bbr_state_value NOTIFIED 2>/dev/null || true)"
    [[ "$notified" != "yes" ]] || return 0
    case "$status" in
        active)
            kernel="$(read_bbr_state_value CURRENT_KERNEL 2>/dev/null || uname -r)"
            version="$(read_bbr_state_value BBR_VERSION 2>/dev/null || true)"
            congestion="$(read_bbr_state_value CONGESTION_CONTROL 2>/dev/null || true)"
            qdisc="$(read_bbr_state_value DEFAULT_QDISC 2>/dev/null || true)"
            log_success "BBRv3 重启恢复完成：内核 ${kernel}，BBR v${version}，${congestion}/${qdisc}"
            mark_bbr_state_notified
            ;;
        verification_failed)
            kernel="$(read_bbr_state_value CURRENT_KERNEL 2>/dev/null || uname -r)"
            log_error "BBRv3 重启恢复未通过，当前内核：${kernel}；请进入系统状态页检查"
            mark_bbr_state_notified
            ;;
    esac
}

schedule_bbr_reboot() {
    local delay="${BBR_REBOOT_DELAY:-8}" unit_name systemctl_path
    systemctl_path="$(command -v systemctl)"
    unit_name="vps-tool-bbr-reboot-$(beijing_date '+%s')-$$"
    sync
    if systemd-run --unit="$unit_name" --on-active="${delay}s" \
        "$systemctl_path" reboot >> "$APP_LOG_FILE" 2>&1; then
        BBR_REBOOT_SCHEDULED="yes"
        log_success "重启任务已安排，服务器将在 ${delay} 秒后重启"
        log_info "SSH 断开后请等待服务器启动，再使用原端口重新连接并运行 sudo vps-tool"
        return 0
    fi
    log_error "无法安排自动重启，请手动执行 sudo reboot"
    return 1
}

install_bbr_interactive() {
    BBR_REBOOT_SCHEDULED="no"
    BBR_REBOOT_REQUIRED="no"
    ui_header
    ui_title "BBRv3 内核配置"
    check_supported_os
    ui_section "01" "安装说明"
    ui_kv "当前内核" "$(uname -r)"
    ui_kv "上游项目" "${C_CYAN}${BBR_REPOSITORY_URL}${C_RESET}"
    ui_kv "重启保护" "${C_GREEN}✔ 保存状态后统一重启${C_RESET}"
    ui_kv "恢复方式" "${C_GREEN}✔ 开机自动验证并启用 BBR + FQ${C_RESET}"
    printf '\n'
    confirm "下载并运行 Actions-bbr-v3 安装器" "Y" || { log_warn "已取消 BBRv3 安装"; return 0; }

    command_exists curl || { log_error "未找到 curl"; return 1; }
    local temp_dir installer session_log target original_boot original_kernel installer_result=0
    local install_completed="no" reboot_intercepted="no" reboot_deferred="no"
    local managed_reboot_prompt="no"
    temp_dir="$(mktemp -d)"
    installer="${temp_dir}/actions-bbr-v3-install.sh"
    session_log="${temp_dir}/installer-session.log"

    log_info "正在下载 BBRv3 安装器..."
    curl --fail --silent --show-error --location --connect-timeout 15 \
        --output "$installer" "$BBR_INSTALLER_URL" \
        || { log_error "BBRv3 安装器下载失败"; rm -rf "$temp_dir"; return 1; }
    [[ -s "$installer" ]] || { log_error "下载的安装器为空"; rm -rf "$temp_dir"; return 1; }
    chmod 700 "$installer"
    if command_exists sha256sum; then
        log_info "上游原始安装器 SHA256：$(sha256sum "$installer" | awk '{print $1}')"
    fi
    if prepare_bbr_installer_reboot_handoff "$installer"; then
        managed_reboot_prompt="yes"
        log_info "已将上游重启步骤切换为 VPS Tool 安全重启流程"
    else
        log_warn "未识别上游重启提示，将使用运行时重启保护"
    fi

    original_boot="$(current_boot_id)"
    original_kernel="$(uname -r)"
    write_bbr_state "installing" "no" "unknown" "$original_boot" "$original_kernel" \
        "UPSTREAM_INSTALLER_RUNNING" "yes"
    if setup_bbr_resume_service; then
        log_success "已启用 BBRv3 重启后自动恢复检查"
    else
        log_warn "无法启用开机恢复服务；重启后再次运行 sudo vps-tool 仍会自动检查"
    fi
    trap 'remove_bbr_resume_service; write_bbr_state "installer_failed" "no" "unknown" "$original_boot" "$original_kernel" "INSTALL_INTERRUPTED" "yes"; rm -rf "$temp_dir"; exit 130' INT TERM
    log_success "安装器已下载；上游重启请求将由 VPS Tool 接管"

    run_bbr_installer_guarded "$installer" "$temp_dir" "$session_log" || installer_result=$?
    [[ -f "${temp_dir}/reboot-requested" ]] && reboot_intercepted="yes"
    grep -q '内核安装并配置完成' "$session_log" 2>/dev/null && install_completed="yes"
    grep -q '请记得稍后手动重启' "$session_log" 2>/dev/null && reboot_deferred="yes"
    if grep -q '内核安装或引导更新失败' "$session_log" 2>/dev/null; then
        installer_result=1
    fi
    target="$(latest_installed_bbr_kernel)"
    if [[ ( "$install_completed" == "yes" || "$reboot_intercepted" == "yes" ) && -z "$target" ]]; then
        installer_result=1
        log_error "上游提示内核安装完成，但系统中未检测到 BBRv3 内核包"
    fi

    if (( installer_result != 0 )); then
        write_bbr_state "installer_failed" "no" "${target:-unknown}" "$original_boot" "$original_kernel" \
            "UPSTREAM_INSTALLER_FAILED" "yes"
        remove_bbr_resume_service
        log_error "BBRv3 安装器执行失败，详情见 ${APP_LOG_FILE}"
        rm -rf "$temp_dir"
        trap - INT TERM
        return 1
    fi

    rm -rf "$temp_dir"
    trap - INT TERM
    if [[ "$install_completed" == "yes" || "$reboot_intercepted" == "yes" \
        || ( -n "$target" && "$target" != "$original_kernel" ) ]]; then
        BBR_REBOOT_REQUIRED="yes"
        write_bbr_state "pending_reboot" "yes" "$target" "$original_boot" "$original_kernel" \
            "WAITING_FOR_REBOOT" "yes"

        ui_section "02" "内核安装结果"
        ui_kv "当前内核" "$original_kernel"
        ui_kv "目标内核" "${C_GREEN}${target}${C_RESET}"
        ui_kv "流程状态" "${C_YELLOW}等待重启${C_RESET}"

        ui_section "03" "重启与恢复"
        ui_kv "重启保护" "已保存安装状态"
        ui_kv "开机任务" "自动验证新内核并启用 BBR + FQ"
        ui_kv "恢复入口" "sudo vps-tool"
        printf '\n'
        if [[ "$reboot_intercepted" == "yes" ]]; then
            log_info "已接收上游安装器的立即重启选择"
            schedule_bbr_reboot || return 0
        elif [[ "$managed_reboot_prompt" == "no" && "$reboot_deferred" == "yes" ]]; then
            log_warn "已按上游安装器中的选择暂缓重启；稍后执行 sudo reboot"
        elif confirm "是否现在安全重启服务器" "Y"; then
            schedule_bbr_reboot || return 0
        else
            log_warn "已暂缓重启；稍后执行 sudo reboot，开机后将自动完成验证"
        fi
        return 0
    fi

    remove_bbr_resume_service
    if bbr_runtime_active; then
        write_bbr_state "active" "no" "${target:-$(uname -r)}" "$original_boot" "$original_kernel" \
            "BBRv3_ALREADY_ACTIVE" "yes"
        log_success "BBRv3 已经在当前内核中生效，无需重启"
    else
        write_bbr_state "no_change" "no" "${target:-unknown}" "$original_boot" "$original_kernel" \
            "NO_NEW_KERNEL_DETECTED" "yes"
        log_warn "上游流程已结束，但未检测到需要重启的新 BBRv3 内核"
    fi
}
