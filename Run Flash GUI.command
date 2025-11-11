#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "${SCRIPT_DIR}/bin"

PYTHON_BIN="${MAIN_HUB_PYTHON:-python3}"
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  osascript -e 'display alert "Flash GUI" message "python3 was not found on this Mac. Install Python 3 and try again."'
  exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/bin/flash_gui.py"
