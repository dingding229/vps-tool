#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
temp_dir="$(mktemp -d)"
cleanup() {
    python3 - "$temp_dir" <<'PY'
from pathlib import Path
import shutil, sys
shutil.rmtree(Path(sys.argv[1]), ignore_errors=True)
PY
}
trap cleanup EXIT

mkdir -p "${temp_dir}/usr/local/sbin"
ln -s "$ROOT_DIR/vps-init.sh" "${temp_dir}/usr/local/sbin/vps-tool"
help_output="$(bash "${temp_dir}/usr/local/sbin/vps-tool" --help)"
grep -q '^VPS Tool 0.5.0$' <<< "$help_output"
grep -q -- '--enable-root' <<< "$help_output"
grep -q -- '--vnstat' <<< "$help_output"
grep -q -- '--update' <<< "$help_output"
printf 'symlink entrypoint resolution: OK\n'

# 再验证一层相对符号链接，避免快捷命令经多级链接后再次使用错误目录。
ln -s vps-tool "${temp_dir}/usr/local/sbin/vps-tool-relative"
relative_output="$(bash "${temp_dir}/usr/local/sbin/vps-tool-relative" --help)"
grep -q '^VPS Tool 0.5.0$' <<< "$relative_output"
printf 'relative symlink entrypoint resolution: OK\n'
