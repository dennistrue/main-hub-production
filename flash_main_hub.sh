#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: ./flash_main_hub.sh --serial <serial> --password <softap-password> [--port <serial-port>] [--skip-ssid]

Arguments:
  --serial, -s      Required per-unit serial suffix (alphanumeric/_/-).
  --password, -w    Required SoftAP password (8-63 ASCII characters).
  --port, -p        Serial/USB port (default \$MAIN_HUB_SERIAL_PORT or /dev/cu.SLAB_USBtoUART).
  --skip-ssid       Skip Wi-Fi provisioning after flashing.
  --help, -h        Show this message.
USAGE
}

SERIAL=""
PORT="${MAIN_HUB_SERIAL_PORT:-/dev/cu.SLAB_USBtoUART}"
AP_PASSWORD="${MAIN_HUB_AP_PASSWORD:-}"
SKIP_SSID=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--serial)
      SERIAL="${2:-}"
      shift 2
      ;;
    -p|--port)
      PORT="${2:-}"
      shift 2
      ;;
    -w|--password)
      AP_PASSWORD="${2:-}"
      shift 2
      ;;
    --skip-ssid)
      SKIP_SSID=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${SERIAL}" ]]; then
  read -r -p "Enter serial suffix (alphanumeric/_/-): " SERIAL
fi

if [[ ! "${SERIAL}" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "Error: serial must be alphanumeric and may include _ or -." >&2
  exit 1
fi
if [[ ${#SERIAL} -gt 50 ]]; then
  echo "Error: serial exceeds maximum supported length (50 characters)." >&2
  exit 1
fi

if [[ -z "${AP_PASSWORD}" ]]; then
  read -r -s -p "Enter SoftAP password (8-63 ASCII characters): " AP_PASSWORD
  echo
fi

if [[ ${#AP_PASSWORD} -lt 8 || ${#AP_PASSWORD} -gt 63 ]]; then
  echo "Error: password must be between 8 and 63 characters." >&2
  exit 1
fi
if ! [[ "${AP_PASSWORD}" =~ ^[[:print:]]+$ ]]; then
  echo "Error: password must contain printable ASCII characters only." >&2
  exit 1
fi

if [[ "$(uname -s 2>/dev/null || echo unknown)" != "Darwin" ]]; then
  echo "Error: flash_main_hub.sh currently supports macOS only." >&2
  exit 1
fi

PRODUCTION_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASES_DIR="${PRODUCTION_ROOT}/release"
TOOLS_DIR="${PRODUCTION_ROOT}/tools/esptool"
ESPTOOL=""
ESPEFUSE=""
ESPSECURE_PYTHON=""
ESPSECURE_TOOL=""
FLASH_ENCRYPTION_KEY_FILE="${FLASH_ENCRYPTION_KEY_FILE:-${PRODUCTION_ROOT}/keys/flash_encryption_key.bin}"
FLASH_ENCRYPTION_ENABLED="${FLASH_ENCRYPTION_ENABLED:-1}"
LOG_DIR="${PRODUCTION_ROOT}/logs"
mkdir -p "${LOG_DIR}"

TEMP_FILES=()
cleanup() {
  local file
  for file in "${TEMP_FILES[@]:-}"; do
    [[ -n "${file}" && -f "${file}" ]] && rm -f "${file}"
  done
}
trap cleanup EXIT

list_port_holders() {
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  lsof -n "${PORT}" 2>/dev/null | awk 'NR>1 {printf "%s\t%s\t%s\n", $1, $2, $3}'
}

diagnose_serial_port_failure() {
  if [[ ! -e "${PORT}" ]]; then
    echo "Serial port ${PORT} not found. Check the USB cable and --port argument." >&2
    return
  fi
  local holders
  holders="$(list_port_holders || true)"
  if [[ -n "${holders}" ]]; then
    echo "Serial port ${PORT} is busy. Close the following processes and retry:" >&2
    while IFS=$'\t' read -r cmd pid user; do
      printf '  %s (pid %s, user %s)\n' "${cmd}" "${pid}" "${user}" >&2
    done <<<"${holders}"
  fi
}

ensure_serial_port_ready() {
  local wait_attempts="${MAIN_HUB_PORT_WAIT_ATTEMPTS:-10}"
  local attempt
  for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
    if [[ ! -e "${PORT}" ]]; then
      echo "Waiting for serial port ${PORT} to appear (${attempt}/${wait_attempts})..." >&2
      sleep 1
      continue
    fi
    local holders
    holders="$(list_port_holders || true)"
    if [[ -n "${holders}" ]]; then
      if (( attempt == 1 )); then
        echo "Serial port ${PORT} is currently in use:" >&2
      else
        echo "Serial port ${PORT} is still in use (${attempt}/${wait_attempts})." >&2
      fi
      while IFS=$'\t' read -r cmd pid user; do
        printf '  %s (pid %s, user %s)\n' "${cmd}" "${pid}" "${user}" >&2
      done <<<"${holders}"
      sleep 1
      continue
    fi
    return 0
  done

  if [[ ! -e "${PORT}" ]]; then
    echo "Error: serial port ${PORT} did not appear. Verify the device connection or pass --port." >&2
  else
    echo "Error: serial port ${PORT} remained busy after ${wait_attempts} attempts." >&2
  fi
  exit 1
}

read_efuse_summary() {
  local attempts=0
  local output=""
  while (( attempts < 3 )); do
    if output="$("${ESPEFUSE}" --port "${PORT}" summary 2>&1)"; then
      printf '%s' "${output}" | tr -d '\r'
      return 0
    else
      local status=$?
      attempts=$((attempts + 1))
      echo "Warning: espefuse summary attempt ${attempts} failed with exit code ${status}." >&2
      if [[ -n "${output}" ]]; then
        echo "${output}" >&2
      fi
      ensure_serial_port_ready
      sleep 1
    fi
  done
  return 1
}

if [[ ! -d "${RELEASES_DIR}" ]]; then
  echo "Error: release directory missing at ${RELEASES_DIR}." >&2
  exit 1
fi


select_tool_binaries() {
  local arch
  arch="$(uname -m 2>/dev/null || echo "x86_64")"
  if [[ "${arch}" == "arm64" || "${arch}" == "aarch64" ]]; then
    ESPTOOL="${TOOLS_DIR}/macos-arm64/esptool"
    ESPEFUSE="${TOOLS_DIR}/macos-arm64/espefuse"
  else
    ESPTOOL="${TOOLS_DIR}/macos-amd64/esptool"
    ESPEFUSE="${TOOLS_DIR}/macos-amd64/espefuse"
  fi

  if [[ ! -x "${ESPTOOL}" ]]; then
    echo "Error: esptool binary not found at ${ESPTOOL}. Run build_output.sh to refresh tools." >&2
    exit 1
  fi
  if [[ ! -x "${ESPEFUSE}" ]]; then
    echo "Error: espefuse binary not found at ${ESPEFUSE}. Run build_output.sh to refresh tools." >&2
    exit 1
  fi
}

detect_espsecure_python() {
  if [[ -n "${ESPSECURE_PYTHON}" && -x "${ESPSECURE_PYTHON}" ]]; then
    return 0
  fi

  local candidates=()
  if [[ -n "${PLATFORMIO_CORE_DIR:-}" ]]; then
    candidates+=("${PLATFORMIO_CORE_DIR}/penv/bin/python")
  fi
  candidates+=("${HOME}/.platformio/penv/bin/python")
  candidates+=("python3")

  local candidate
  for candidate in "${candidates[@]}"; do
    if [[ -x "${candidate}" ]]; then
      ESPSECURE_PYTHON="${candidate}"
      return 0
    fi
    if command -v "${candidate}" >/dev/null 2>&1; then
      ESPSECURE_PYTHON="$(command -v "${candidate}")"
      return 0
    fi
  done
  return 1
}

detect_espsecure_tool() {
  if [[ -n "${ESPSECURE_TOOL}" && -f "${ESPSECURE_TOOL}" ]]; then
    return 0
  fi

  local bases=()
  if [[ -n "${PLATFORMIO_CORE_DIR:-}" ]]; then
    bases+=("${PLATFORMIO_CORE_DIR}")
  fi
  bases+=("${HOME}/.platformio")

  local base
  for base in "${bases[@]}"; do
    local candidate="${base}/packages/tool-esptoolpy/espsecure.py"
    if [[ -f "${candidate}" ]]; then
      ESPSECURE_TOOL="${candidate}"
      return 0
    fi
  done

  if command -v espsecure.py >/dev/null 2>&1; then
    ESPSECURE_TOOL="$(command -v espsecure.py)"
    return 0
  fi

  return 1
}

ensure_espsecure() {
  if ! detect_espsecure_python; then
    echo "Error: unable to locate python interpreter for espsecure.py." >&2
    exit 1
  fi
  if ! detect_espsecure_tool; then
    echo "Error: unable to locate espsecure.py tool." >&2
    exit 1
  fi
}

select_tool_binaries

if [[ ! -f "${FLASH_ENCRYPTION_KEY_FILE}" ]]; then
  echo "Error: flash encryption key not found at ${FLASH_ENCRYPTION_KEY_FILE}." >&2
  echo "Place the key (flash_encryption_key.bin) under main-hub-production/keys/ or set FLASH_ENCRYPTION_KEY_FILE." >&2
  exit 1
fi

echo "Updating production repo..."
if ! git -C "${PRODUCTION_ROOT}" fetch --quiet --tags; then
  echo "Error: unable to fetch updates. Verify network connectivity and Git credentials." >&2
  exit 1
fi
if ! git -C "${PRODUCTION_ROOT}" pull --ff-only; then
  echo "Error: git pull failed. Resolve merge/credential issues before flashing." >&2
  exit 1
fi

MANIFEST="${RELEASES_DIR}/manifest.json"
if [[ ! -f "${MANIFEST}" ]]; then
  echo "Error: manifest.json missing in ${RELEASES_DIR}." >&2
  exit 1
fi

eval "$(python3 - "${MANIFEST}" <<'PY'
import json, shlex, sys
from pathlib import Path
manifest = Path(sys.argv[1])
data = json.loads(manifest.read_text())
arts = data.get('artifacts', {})
encs = data.get('encrypted_artifacts') or {}
def emit(key, value):
    if value is None:
        raise SystemExit(f"Missing manifest value: {key}")
    print(f"{key}={shlex.quote(str(value))}")
def emit_optional(key, value):
    if value is None:
        print(f"{key}=")
    else:
        print(f"{key}={shlex.quote(str(value))}")
emit('FACTORY_SSID', data.get('factory_ssid', 'Main0000'))
emit('FACTORY_PASSWORD', data.get('ap_password', '12345678'))
emit('TARGET_IP', data.get('target_ip', '192.168.4.1'))
emit('ART_BOOTLOADER', arts.get('bootloader'))
emit('ART_BOOT_APP0', arts.get('boot_app0'))
emit('ART_PARTITIONS', arts.get('partitions'))
emit('ART_FIRMWARE', arts.get('firmware'))
emit('ART_SPIFFS', arts.get('spiffs'))
emit_optional('ENC_BOOTLOADER', encs.get('bootloader'))
emit_optional('ENC_BOOT_APP0', encs.get('boot_app0'))
emit_optional('ENC_PARTITIONS', encs.get('partitions'))
emit_optional('ENC_FIRMWARE', encs.get('firmware'))
emit_optional('ENC_SPIFFS', encs.get('spiffs'))
PY
)" || {
  echo "Error: manifest missing required fields." >&2
  exit 1
}

BOOTLOADER_BIN="${RELEASES_DIR}/${ART_BOOTLOADER}"
BOOT_APP0_BIN="${RELEASES_DIR}/${ART_BOOT_APP0}"
PARTITIONS_BIN="${RELEASES_DIR}/${ART_PARTITIONS}"
FIRMWARE_BIN="${RELEASES_DIR}/${ART_FIRMWARE}"
SPIFFS_BIN="${RELEASES_DIR}/${ART_SPIFFS}"

ENC_BOOTLOADER_BIN=""
ENC_BOOT_APP0_BIN=""
ENC_PARTITIONS_BIN=""
ENC_FIRMWARE_BIN=""
ENC_SPIFFS_BIN=""

if [[ -n "${ENC_BOOTLOADER:-}" ]]; then
  ENC_BOOTLOADER_BIN="${RELEASES_DIR}/${ENC_BOOTLOADER}"
fi
if [[ -n "${ENC_BOOT_APP0:-}" ]]; then
  ENC_BOOT_APP0_BIN="${RELEASES_DIR}/${ENC_BOOT_APP0}"
fi
if [[ -n "${ENC_PARTITIONS:-}" ]]; then
  ENC_PARTITIONS_BIN="${RELEASES_DIR}/${ENC_PARTITIONS}"
fi
if [[ -n "${ENC_FIRMWARE:-}" ]]; then
  ENC_FIRMWARE_BIN="${RELEASES_DIR}/${ENC_FIRMWARE}"
fi
if [[ -n "${ENC_SPIFFS:-}" ]]; then
  ENC_SPIFFS_BIN="${RELEASES_DIR}/${ENC_SPIFFS}"
fi

select_artifact_path() {
  local preferred="$1"
  local fallback="$2"
  if [[ -n "${preferred}" && -f "${preferred}" ]]; then
    echo "${preferred}"
    return 0
  fi
  if [[ -n "${fallback}" && -f "${fallback}" ]]; then
    echo "${fallback}"
    return 0
  fi
  return 1
}

USE_PRE_ENCRYPTED=0

choose_or_fail() {
  local preferred="$1"
  local fallback="$2"
  local label="$3"
  local chosen
  if ! chosen="$(select_artifact_path "${preferred}" "${fallback}")"; then
    echo "Error: required artifact '${label}' missing (checked '${preferred:-<none>}' and '${fallback:-<none>}')." >&2
    exit 1
  fi
  if [[ -n "${preferred}" && "${chosen}" == "${preferred}" ]]; then
    USE_PRE_ENCRYPTED=1
  fi
  printf '%s' "${chosen}"
}


BOOTLOADER_BIN="$(choose_or_fail "${ENC_BOOTLOADER_BIN}" "${BOOTLOADER_BIN}" "bootloader")"
BOOT_APP0_BIN="$(choose_or_fail "${ENC_BOOT_APP0_BIN}" "${BOOT_APP0_BIN}" "boot_app0")"
PARTITIONS_BIN="$(choose_or_fail "${ENC_PARTITIONS_BIN}" "${PARTITIONS_BIN}" "partitions")"
FIRMWARE_BIN="$(choose_or_fail "${ENC_FIRMWARE_BIN}" "${FIRMWARE_BIN}" "firmware")"
SPIFFS_BIN="$(choose_or_fail "${ENC_SPIFFS_BIN}" "${SPIFFS_BIN}" "spiffs")"

if [[ "${FLASH_ENCRYPTION_ENABLED}" == "1" ]]; then
  USE_PRE_ENCRYPTED=1
else
  USE_PRE_ENCRYPTED=0
fi

if (( USE_PRE_ENCRYPTED )); then
  echo "Using pre-encrypted release bundle for flashing."
fi

needs_flash_encryption_setup() {
  local summary
  ensure_serial_port_ready
  if ! summary="$(read_efuse_summary)"; then
    echo "Error: unable to read eFuse summary via ${ESPEFUSE}." >&2
    diagnose_serial_port_failure
    exit 1
  fi
  local line
  line="$(grep 'FLASH_CRYPT_CNT' <<<"${summary}" || true)"
  if [[ "${line}" =~ "= 0" ]]; then
    return 0
  fi
  return 1
}

burn_flash_encryption() {
  echo "Burning flash encryption key and eFuses..."
  ensure_serial_port_ready
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_key flash_encryption "${FLASH_ENCRYPTION_KEY_FILE}"
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_efuse FLASH_CRYPT_CONFIG 0xf
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_efuse FLASH_CRYPT_CNT
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_efuse DISABLE_DL_DECRYPT 1
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_efuse DISABLE_DL_CACHE 1
  echo "Flash encryption eFuses programmed."
}

prepare_flash_encryption() {
  if needs_flash_encryption_setup; then
    burn_flash_encryption
  else
    echo "Flash encryption already enabled on target."
  fi
}

if [[ "${FLASH_ENCRYPTION_ENABLED}" == "1" ]]; then
  if [[ ! -f "${FLASH_ENCRYPTION_KEY_FILE}" ]]; then
    echo "Error: flash encryption key not found at ${FLASH_ENCRYPTION_KEY_FILE}." >&2
    echo "Place the key (flash_encryption_key.bin) under main-hub-production/keys/ or set FLASH_ENCRYPTION_KEY_FILE." >&2
    exit 1
  fi
  prepare_flash_encryption
else
  echo "Flash encryption disabled for this run; writing plaintext images."
fi

flash_cmd=(
  "${ESPTOOL}"
  --chip esp32
  --port "${PORT}"
  --baud "${MAIN_HUB_FLASH_BAUD:-921600}"
  --before default_reset
  --after hard_reset
  write_flash
)

if [[ "${FLASH_ENCRYPTION_ENABLED}" == "1" ]]; then
  if (( USE_PRE_ENCRYPTED )); then
    flash_cmd+=(--no-compress)
  else
    flash_cmd+=(--encrypt)
  fi
else
  flash_cmd+=(-z)
fi

flash_cmd+=(
  --flash_mode dio
  --flash_freq 40m
  --flash_size detect
  0x1000 "${BOOTLOADER_BIN}"
  0x8000 "${PARTITIONS_BIN}"
  0xe000 "${BOOT_APP0_BIN}"
  0x10000 "${FIRMWARE_BIN}"
  0x290000 "${SPIFFS_BIN}"
)

ensure_serial_port_ready

echo "Flashing bundle $(basename "${RELEASES_DIR}") to ${PORT}..."
"${flash_cmd[@]}"

echo "Flash complete."

log_entry() {
  local status="$1"
  printf '%s,%s,%s,%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${SERIAL}" "$(basename "${RELEASES_DIR}")" "${status}" >> "${LOG_DIR}/flash_log.csv"
}

restore_wifi_after_provision() {
  local device="${WIFI_RESTORE_DEVICE:-}"
  local ssid="${WIFI_RESTORE_SSID:-}"
  if [[ -n "${device}" && -n "${ssid}" && "${ssid}" != "You are not associated with an AirPort network." ]]; then
    networksetup -setairportnetwork "${device}" "${ssid}" >/dev/null 2>&1 || true
  fi
}

provision_serial() {
  if ! command -v networksetup >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    echo "Skipping SSID provisioning: networksetup/curl not available." >&2
    return 1
  fi

  local wifi_device="${WIFI_DEVICE:-}"
  if [[ -z "${wifi_device}" ]]; then
    wifi_device=$(networksetup -listallhardwareports | awk '/Hardware Port: Wi-Fi/{getline; print $2; exit}')
  fi
  if [[ -z "${wifi_device}" ]]; then
    echo "Unable to determine Wi-Fi interface. Set WIFI_DEVICE and retry." >&2
    return 1
  fi

  WIFI_RESTORE_DEVICE="${wifi_device}"
  WIFI_RESTORE_SSID=$(networksetup -getairportnetwork "${wifi_device}" 2>/dev/null | awk -F': ' 'NR==1{print $2}')
  trap restore_wifi_after_provision RETURN

  echo "Connecting ${wifi_device} to factory SSID ${FACTORY_SSID}..."
  if ! networksetup -setairportnetwork "${wifi_device}" "${FACTORY_SSID}" "${FACTORY_PASSWORD}"; then
    echo "Failed to join ${FACTORY_SSID}." >&2
    trap - RETURN
    restore_wifi_after_provision
    return 1
  fi

  echo "Waiting for device ${TARGET_IP}..."
  local attempt=0
  until ping -c 1 -W 1000 "${TARGET_IP}" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    if (( attempt > 20 )); then
      echo "Device did not respond at ${TARGET_IP}." >&2
      trap - RETURN
      restore_wifi_after_provision
      return 1
    fi
    sleep 1
  done

  echo "Provisioning SSID via /debug/update"
  curl --silent --show-error --fail \
    --user "${MAIN_HUB_DEBUG_USER:-admin}:${MAIN_HUB_DEBUG_PASSWORD:-S1mpl3Hub#2025}" \
    --data-urlencode "serial=${SERIAL}" \
    --data-urlencode "password=${AP_PASSWORD}" \
    "http://${TARGET_IP}/debug/update"

  echo "SSID updated. Device will reboot as Main${SERIAL}."
  trap - RETURN
  restore_wifi_after_provision
}

if (( SKIP_SSID == 0 )); then
  if provision_serial; then
    log_entry "success"
  else
    echo "Warning: SSID provisioning failed; flash logged only." >&2
    log_entry "flash_only"
  fi
else
  log_entry "flash_only"
fi

echo "Done."
