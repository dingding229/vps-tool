#!/usr/bin/env bash
set -Euo pipefail

REPO_OWNER="dingding229"
REPO_NAME="vps-tool"
REPO_BRANCH="main"
INSTALL_DIR="/opt/vps-tool"
ARCHIVE_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}/archive/refs/heads/${REPO_BRANCH}.tar.gz"
APP_TIMEZONE="Asia/Shanghai"
export TZ="$APP_TIMEZONE"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RESET=$'\033[0m'; BOLD=$'\033[1m'; CYAN=$'\033[36m'; GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'
else
    RESET=""; BOLD=""; CYAN=""; GREEN=""; RED=""; YELLOW=""
fi

info()    { printf '%s●%s %s\n' "$CYAN" "$RESET" "$*"; }
success() { printf '%s✔%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s▲%s %s\n' "$YELLOW" "$RESET" "$*"; }
fatal()   { printf '%s✖%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

cleanup() {
    [[ -n "${TEMP_DIR:-}" && -d "${TEMP_DIR:-}" ]] && rm -rf "$TEMP_DIR"
    if [[ -n "${PREVIOUS_INSTALL_DIR:-}" && -d "${PREVIOUS_INSTALL_DIR:-}" ]]; then
        if [[ "${INSTALL_REPLACEMENT_COMPLETE:-0}" == "1" ]]; then
            rm -rf "$PREVIOUS_INSTALL_DIR"
        else
            [[ ! -e "$INSTALL_DIR" ]] || rm -rf "$INSTALL_DIR"
            mv "$PREVIOUS_INSTALL_DIR" "$INSTALL_DIR" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

printf '\n%s%s╭──────────────────────────────────────────────────────────╮%s\n' "$BOLD" "$CYAN" "$RESET"
printf '%s│%s              VPS Tool 一键安装程序                    %s│%s\n' "$CYAN" "$BOLD" "$CYAN" "$RESET"
printf '%s╰──────────────────────────────────────────────────────────╯%s\n\n' "$CYAN" "$RESET"

[[ "$(uname -s)" == "Linux" ]] || fatal "仅支持 Linux VPS"
(( EUID == 0 )) || fatal "请使用 root 运行：sudo bash install.sh"
[[ -r /etc/os-release ]] || fatal "无法识别操作系统"
# shellcheck disable=SC1091
source /etc/os-release
case "${ID:-}" in
    debian)
        [[ "${VERSION_ID%%.*}" =~ ^[0-9]+$ ]] && (( ${VERSION_ID%%.*} >= 12 )) \
            || fatal "仅支持 Debian 12 及以上版本"
        ;;
    ubuntu)
        version_major="${VERSION_ID%%.*}"
        version_minor="${VERSION_ID#*.}"; version_minor="${version_minor%%.*}"
        [[ "$version_major" =~ ^[0-9]+$ && "$version_minor" =~ ^[0-9]+$ ]] \
            || fatal "无法识别 Ubuntu 版本"
        (( version_major > 24 || (version_major == 24 && version_minor >= 4) )) \
            || fatal "仅支持 Ubuntu 24.04 及以上版本"
        ;;
    *) fatal "仅支持 Debian 12+ 或 Ubuntu 24.04+，当前：${PRETTY_NAME:-${ID:-unknown}}" ;;
esac

case "$(uname -m)" in
    x86_64|aarch64|arm64) ;;
    *) fatal "仅支持 x86_64 或 aarch64 架构" ;;
esac

missing=()
for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} > 0 )); then
    info "正在安装必要工具：${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates tar >/dev/null
fi

TEMP_DIR="$(mktemp -d)"
archive="${TEMP_DIR}/vps-tool.tar.gz"
extract_dir="${TEMP_DIR}/extract"
mkdir -p "$extract_dir"

info "正在从 GitHub 下载 VPS Tool..."
curl --fail --silent --show-error --location --connect-timeout 15 \
    --retry 3 --output "$archive" "$ARCHIVE_URL" \
    || fatal "项目下载失败，请检查 GitHub 网络连接"
[[ -s "$archive" ]] || fatal "下载文件为空"

tar -xzf "$archive" -C "$extract_dir" || fatal "项目压缩包解压失败"
source_dir="$(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
[[ -n "$source_dir" \
    && -f "${source_dir}/vps-init.sh" \
    && -f "${source_dir}/install.sh" \
    && -f "${source_dir}/config/defaults.conf" \
    && -f "${source_dir}/lib/common.sh" \
    && -d "${source_dir}/scripts" ]] || fatal "项目文件不完整"
find "$source_dir" -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n \
    || fatal "项目脚本检查未通过"
chmod 700 "${source_dir}/vps-init.sh" "${source_dir}/install.sh"
find "${source_dir}/scripts" -type f -name '*.sh' -exec chmod 700 {} +

mkdir -p "$(dirname "$INSTALL_DIR")"
PREVIOUS_INSTALL_DIR=""
INSTALL_REPLACEMENT_COMPLETE=0
if [[ -d "$INSTALL_DIR" ]]; then
    PREVIOUS_INSTALL_DIR="${INSTALL_DIR}.replacing.$$"
    [[ ! -e "$PREVIOUS_INSTALL_DIR" ]] || fatal "临时替换目录已存在：${PREVIOUS_INSTALL_DIR}"
    warn "检测到已安装版本，将直接替换且不保留旧文件"
    mv "$INSTALL_DIR" "$PREVIOUS_INSTALL_DIR" || fatal "无法替换当前安装目录"
fi
if ! mv "$source_dir" "$INSTALL_DIR"; then
    [[ ! -e "$INSTALL_DIR" ]] || rm -rf "$INSTALL_DIR"
    if [[ -n "$PREVIOUS_INSTALL_DIR" && -d "$PREVIOUS_INSTALL_DIR" ]]         && mv "$PREVIOUS_INSTALL_DIR" "$INSTALL_DIR" 2>/dev/null; then
        PREVIOUS_INSTALL_DIR=""
        fatal "新版本安装失败，已恢复当前版本"
    fi
    fatal "新版本安装失败，退出时将再次恢复当前版本"
fi
INSTALL_REPLACEMENT_COMPLETE=1
if [[ -n "$PREVIOUS_INSTALL_DIR" ]]; then
    rm -rf "$PREVIOUS_INSTALL_DIR"
    PREVIOUS_INSTALL_DIR=""
fi

ln -sfn "$INSTALL_DIR/vps-init.sh" /usr/local/sbin/vps-tool
success "安装完成：${INSTALL_DIR}"
success "快捷命令：sudo vps-tool"
printf '\n'

if [[ "${VPS_TOOL_INSTALL_ONLY:-0}" == "1" ]]; then
    info "已按安装模式退出，未启动交互界面"
    exit 0
fi

exec bash "$INSTALL_DIR/vps-init.sh" --interactive
