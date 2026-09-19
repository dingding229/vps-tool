#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
if ! command -v shellcheck >/dev/null 2>&1; then
    echo "shellcheck 未安装，跳过"
    exit 0
fi
shellcheck -x "$ROOT_DIR/vps-init.sh" "$ROOT_DIR"/lib/*.sh "$ROOT_DIR"/scripts/*.sh
