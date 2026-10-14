#!/bin/bash
set -euo pipefail
umask 077
export PYTHONDONTWRITEBYTECODE=1
echo 'BITCLIPBOARD_INSTALL {"stage":"preparing"}'
TASK_RUNTIME="${1:-$HOME/Library/Application Support/BitClipboard/SemanticSearch}"
TASK_RESOURCES="$(cd "$(dirname "$0")" && pwd)"
TASK_PYTHON="${BITCLIPBOARD_PYTHON:-}"
if [[ -z "$TASK_PYTHON" ]]; then
    for candidate in /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
        if [[ -x "$candidate" ]] && "$candidate" -c 'import sys; sys.exit(0 if (3, 10) <= sys.version_info[:2] < (3, 15) else 1)'; then
            TASK_PYTHON="$candidate"
            break
        fi
    done
fi
if [[ -z "$TASK_PYTHON" ]]; then
    echo '请安装 Python 3.10–3.14 后重试（支持 Homebrew 或 python.org）。' >&2
    exit 1
fi
mkdir -p "$TASK_RUNTIME"
chmod 700 "$TASK_RUNTIME"
rm -f "$TASK_RUNTIME/ready"
"$TASK_PYTHON" -m venv "$TASK_RUNTIME/venv"
"$TASK_RUNTIME/venv/bin/python3" -m pip install --upgrade 'pip>=25.2' >&2
exec "$TASK_RUNTIME/venv/bin/python3" -u "$TASK_RESOURCES/install_runtime.py" --runtime "$TASK_RUNTIME"
