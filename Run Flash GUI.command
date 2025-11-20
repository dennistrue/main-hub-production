#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="${SCRIPT_DIR}"

update_repo() {
  if ! command -v git >/dev/null 2>&1; then
    osascript -e 'display alert "Flash GUI" message "Git is required but was not found. Install Git and try again."'
    exit 1
  fi

  local head_before head_after
  head_before="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"

  echo "Checking for updates..."
  if ! git -C "${REPO_DIR}" fetch --quiet --tags; then
    osascript -e 'display alert "Flash GUI" message "Failed to fetch updates (git fetch). Check network/credentials and retry."'
    exit 1
  fi
  if ! git -C "${REPO_DIR}" pull --ff-only; then
    osascript -e 'display alert "Flash GUI" message "Failed to pull latest changes. Resolve Git issues and retry."'
    exit 1
  fi

  head_after="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "${head_before}" && -n "${head_after}" && "${head_after}" != "${head_before}" ]]; then
    echo "Repository updated; restarting launcher to pick up changes..."
    exec "$0" "$@"
  fi
}

update_repo "$@"
cd "${SCRIPT_DIR}/bin"

PYTHON_BIN="${MAIN_HUB_PYTHON:-python3}"
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  osascript -e 'display alert "Flash GUI" message "python3 was not found on this Mac. Install Python 3 and try again."'
  exit 1
fi

exec "${PYTHON_BIN}" "${SCRIPT_DIR}/bin/flash_gui.py"
