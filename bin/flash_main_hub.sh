#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: ./flash_main_hub.sh --serial <serial> --password <softap-password> [--port <serial-port>] [--wifi-provision]

Arguments:
  --serial, -s      Required per-unit serial suffix (alphanumeric/_/-).
  --password, -w    Required SoftAP password (8-63 ASCII characters).
  --port, -p        Serial/USB port (default \$MAIN_HUB_SERIAL_PORT or /dev/cu.SLAB_USBtoUART).
  --wifi-provision  Rejoin the factory SSID and call /debug/update after flashing (default: off).
  --skip-ssid       Legacy alias for disabling Wi-Fi provisioning (now the default).
  --help, -h        Show this message.
USAGE
}

SERIAL=""
PORT="${MAIN_HUB_SERIAL_PORT:-auto}"
AP_PASSWORD="${MAIN_HUB_AP_PASSWORD:-}"
WIFI_PROVISION="${MAIN_HUB_WIFI_PROVISION:-0}"

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
    --wifi-provision)
      WIFI_PROVISION=1
      shift
      ;;
    --skip-ssid)
      WIFI_PROVISION=0
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

sanitize_serial_suffix() {
  python3 - "$1" <<'PY'
import sys
value = sys.argv[1]
filtered = []
for ch in value:
    if ch.isalnum() or ch in "_-":
        filtered.append(ch)
sanitized = "".join(filtered)[:28]
if not sanitized:
    raise SystemExit("Serial suffix must retain at least one valid character after sanitization.")
print(sanitized)
PY
}

SERIAL_SANITIZED="$(sanitize_serial_suffix "${SERIAL}")"
if [[ "${SERIAL_SANITIZED}" != "${SERIAL}" ]]; then
  echo "Serial sanitized to '${SERIAL_SANITIZED}' for factory config."
fi
SERIAL="${SERIAL_SANITIZED}"

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
ESPSECURE=""
FLASH_ENCRYPTION_KEY_FILE="${FLASH_ENCRYPTION_KEY_FILE:-${PRODUCTION_ROOT}/keys/flash_encryption_key.bin}"
FLASH_ENCRYPTION_ENABLED="${FLASH_ENCRYPTION_ENABLED:-1}"
LOG_DIR="${PRODUCTION_ROOT}/logs"
FACTORY_CFG_TOOL="${PRODUCTION_ROOT}/tools/gen_factory_payload.py"
FLASH_ENV_VERSION="1.0.2"
FACTORY_PARTITION_SIZE_HEX="${FACTORY_PARTITION_SIZE:-0x10000}"
FACTORY_CFG_PLAIN_PATH=""
FACTORY_CFG_FLASH_PATH=""
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
  if [[ "${PORT}" == "auto" ]]; then
    return 0
  fi
  if ! command -v lsof >/dev/null 2>&1; then
    return 0
  fi
  lsof -n "${PORT}" 2>/dev/null | awk 'NR>1 {printf "%s\t%s\t%s\n", $1, $2, $3}'
}

collect_serial_candidates() {
  local -a candidates=()
  shopt -s nullglob
  local pattern dev existing skip
  for pattern in /dev/cu.usbserial-* /dev/cu.SLAB_USBtoUART /dev/cu.SLAB_USB* /dev/cu.wchusbserial* /dev/cu.usbmodem*; do
    for dev in $pattern; do
      [[ -c "${dev}" ]] || continue
      skip=0
      for existing in "${candidates[@]:-}"; do
        if [[ "${existing}" == "${dev}" ]]; then
          skip=1
          break
        fi
      done
      if (( ! skip )); then
        candidates+=("${dev}")
      fi
    done
  done
  shopt -u nullglob
  if ((${#candidates[@]} > 0)); then
    printf '%s\n' "${candidates[@]}"
  fi
}

auto_select_serial_port() {
  local interactive="${1:-1}"
  local -a candidates=()
  while IFS= read -r dev; do
    candidates+=("${dev}")
  done < <(collect_serial_candidates)

  local count="${#candidates[@]}"
  if (( count == 0 )); then
    if (( interactive )); then
      echo "No USB serial devices detected. Connect a board or pass --port." >&2
    fi
    return 1
  fi

  if (( count == 1 )); then
    PORT="${candidates[0]}"
    if (( interactive )); then
      echo "Auto-selected serial port ${PORT}"
    fi
    return 0
  fi

  if (( ! interactive )); then
    return 2
  fi

  echo "Multiple USB serial devices detected:"
  local idx=1
  for dev in "${candidates[@]:-}"; do
    printf '  [%d] %s\n' "${idx}" "${dev}"
    idx=$((idx + 1))
  done
  while true; do
    read -r -p "Select port [1-${count}] or enter a device path: " choice
    if [[ -z "${choice}" ]]; then
      continue
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      PORT="${candidates[choice-1]}"
      break
    elif [[ -e "${choice}" ]]; then
      PORT="${choice}"
      break
    else
      echo "Invalid selection. Provide a number from the list or a valid device path." >&2
    fi
  done
  echo "Using serial port ${PORT}"
  return 0
}

resolve_serial_port() {
  if [[ -z "${PORT}" || "${PORT}" == "auto" ]]; then
    auto_select_serial_port 1 || PORT="auto"
    return
  fi
  if [[ ! -e "${PORT}" ]]; then
    echo "Serial port ${PORT} not found; attempting auto-detect..." >&2
    PORT="auto"
    auto_select_serial_port 1 || PORT="auto"
  fi
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
    if [[ "${PORT}" == "auto" || -z "${PORT}" ]]; then
      local rc
      auto_select_serial_port 0
      rc=$?
      if [[ "${rc}" == "0" ]]; then
        continue
      elif [[ "${rc}" == "2" ]]; then
        if auto_select_serial_port 1; then
          continue
        fi
      fi
      echo "Waiting for USB serial device to appear (${attempt}/${wait_attempts})..." >&2
      sleep 1
      continue
    fi
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

resolve_serial_port

get_file_size() {
  local file="$1"
  if [[ ! -f "${file}" ]]; then
    echo "Verification error: missing file ${file}" >&2
    return 1
  fi
  if stat -f%z "${file}" >/dev/null 2>&1; then
    stat -f%z "${file}"
  else
    stat -c%s "${file}"
  fi
}

verify_factory_payload_plain() {
  local file="$1"
  python3 - "$file" "$SERIAL" "$AP_PASSWORD" <<'PY'
import binascii, struct, sys
path, expected_serial, expected_password = sys.argv[1:4]
MAGIC = 0x46504346
HEADER_STRUCT = struct.Struct("<IHH")
SERIAL_FIELD_LEN = 32
PASSWORD_FIELD_LEN = 64
RESERVED_LEN = 48
CRC_STRUCT = struct.Struct("<I")

with open(path, "rb") as fh:
    blob = fh.read(HEADER_STRUCT.size + SERIAL_FIELD_LEN + PASSWORD_FIELD_LEN + RESERVED_LEN + CRC_STRUCT.size)

min_len = HEADER_STRUCT.size + SERIAL_FIELD_LEN + PASSWORD_FIELD_LEN + RESERVED_LEN + CRC_STRUCT.size
if len(blob) < min_len:
    raise SystemExit("Factory payload truncated.")

magic, version, flags = HEADER_STRUCT.unpack(blob[:HEADER_STRUCT.size])
if magic != MAGIC:
    raise SystemExit(f"Factory payload magic mismatch: 0x{magic:08x}")

serial_start = HEADER_STRUCT.size
serial_end = serial_start + SERIAL_FIELD_LEN
password_end = serial_end + PASSWORD_FIELD_LEN
reserved_end = password_end + RESERVED_LEN
stored_crc, = CRC_STRUCT.unpack(blob[reserved_end:reserved_end + CRC_STRUCT.size])
calc_crc = binascii.crc32(blob[:reserved_end]) & 0xFFFFFFFF
if calc_crc != stored_crc:
    raise SystemExit("Factory payload CRC mismatch.")

serial = blob[serial_start:serial_end].split(b'\x00', 1)[0].decode('ascii', errors='ignore')
password = blob[serial_end:password_end].split(b'\x00', 1)[0].decode('ascii', errors='ignore')
if serial != expected_serial:
    raise SystemExit(f"Factory payload serial mismatch (got '{serial}' expected '{expected_serial}').")
if password != expected_password:
    raise SystemExit("Factory payload password mismatch.")

print(f"Factory payload verified (serial={serial}, version={version}, flags={flags}).")
PY
}

prepare_factory_payload() {
  if [[ ! -x "${FACTORY_CFG_TOOL}" ]]; then
    echo "Error: factory payload generator missing at ${FACTORY_CFG_TOOL}. Run build_output.sh." >&2
    exit 1
  fi

  local plaintext
  plaintext="$(mktemp)"
  TEMP_FILES+=("${plaintext}")
  python3 "${FACTORY_CFG_TOOL}" \
    --serial "${SERIAL}" \
    --password "${AP_PASSWORD}" \
    --partition-size "${FACTORY_PARTITION_SIZE_HEX}" \
    --output "${plaintext}"
  FACTORY_CFG_PLAIN_PATH="${plaintext}"
  verify_factory_payload_plain "${FACTORY_CFG_PLAIN_PATH}"

  if [[ "${FLASH_ENCRYPTION_ENABLED}" == "1" ]]; then
    local encrypted
    encrypted="$(mktemp)"
    TEMP_FILES+=("${encrypted}")
    "${ESPSECURE}" encrypt_flash_data \
      --keyfile "${FLASH_ENCRYPTION_KEY_FILE}" \
      --address 0x3F0000 \
      --output "${encrypted}" \
      "${FACTORY_CFG_PLAIN_PATH}"
    FACTORY_CFG_FLASH_PATH="${encrypted}"
  else
    FACTORY_CFG_FLASH_PATH="${FACTORY_CFG_PLAIN_PATH}"
  fi
}

verify_flash_plan() {
  local layout=(
    "bootloader;0x1000;0x8000;${BOOTLOADER_BIN}"
    "partitions;0x8000;0x9000;${PARTITIONS_BIN}"
    "boot_app0;0xe000;0x10000;${BOOT_APP0_BIN}"
    "firmware;0x10000;0x150000;${FIRMWARE_BIN}"
    "spiffs;0x290000;0x3F0000;${SPIFFS_BIN}"
    "factory_cfg;0x3F0000;0x400000;${FACTORY_CFG_FLASH_PATH}"
  )
  local ok=1
  echo "Verifying flash layout and region sizes..."
  local entry
  for entry in "${layout[@]}"; do
    IFS=';' read -r name start_hex end_hex path <<<"${entry}"
    if [[ -z "${path}" ]]; then
      echo "Verification error: path for ${name} not set." >&2
      ok=0
      continue
    fi
    local start=$((start_hex))
    local end=$((end_hex))
    local max_size=$((end - start))
    local size
    if ! size="$(get_file_size "${path}")"; then
      ok=0
      continue
    fi
    printf '  %-11s %10d bytes (limit %d)\n' "${name}" "${size}" "${max_size}"
    if (( size > max_size )); then
      echo "Verification error: ${name} exceeds allocated size." >&2
      ok=0
    fi
  done
  if (( ok )); then
    echo "Flash plan validated."
    return 0
  fi
  return 1
}


select_tool_binaries() {
  local arch
  arch="$(uname -m 2>/dev/null || echo "x86_64")"
  if [[ "${arch}" == "arm64" || "${arch}" == "aarch64" ]]; then
    ESPTOOL="${TOOLS_DIR}/macos-arm64/esptool"
    ESPEFUSE="${TOOLS_DIR}/macos-arm64/espefuse"
    ESPSECURE="${TOOLS_DIR}/macos-arm64/espsecure"
  else
    ESPTOOL="${TOOLS_DIR}/macos-amd64/esptool"
    ESPEFUSE="${TOOLS_DIR}/macos-amd64/espefuse"
    ESPSECURE="${TOOLS_DIR}/macos-amd64/espsecure"
  fi

  if [[ ! -x "${ESPTOOL}" ]]; then
    echo "Error: esptool binary not found at ${ESPTOOL}. Run build_output.sh to refresh tools." >&2
    exit 1
  fi
  if [[ ! -x "${ESPEFUSE}" ]]; then
    echo "Error: espefuse binary not found at ${ESPEFUSE}. Run build_output.sh to refresh tools." >&2
    exit 1
  fi
  if [[ ! -x "${ESPSECURE}" ]]; then
    echo "Error: espsecure binary not found at ${ESPSECURE}. Run build_output.sh to refresh tools." >&2
    exit 1
  fi
}

select_tool_binaries

if [[ ! -f "${FLASH_ENCRYPTION_KEY_FILE}" ]]; then
  echo "Error: flash encryption key not found at ${FLASH_ENCRYPTION_KEY_FILE}." >&2
  echo "Place the key (flash_encryption_key.bin) under main-hub-production/keys/ or set FLASH_ENCRYPTION_KEY_FILE." >&2
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
emit('FACTORY_SSID', data.get('factory_ssid', 'CC00-00000000'))
emit('FACTORY_PASSWORD', data.get('ap_password', '12345678'))
emit('TARGET_IP', data.get('target_ip', '192.168.4.1'))
emit('BUNDLE_VERSION', data.get('version'))
emit('BUNDLE_ENVIRONMENT', data.get('environment'))
emit('BUNDLE_COMMIT', data.get('git_commit'))
emit('ART_BOOTLOADER', arts.get('bootloader'))
emit('ART_BOOT_APP0', arts.get('boot_app0'))
emit('ART_PARTITIONS', arts.get('partitions'))
emit('ART_FIRMWARE', arts.get('firmware'))
emit('ART_SPIFFS', arts.get('spiffs'))
emit('ART_FACTORY_CFG', arts.get('factory_cfg'))
emit_optional('ENC_BOOTLOADER', encs.get('bootloader'))
emit_optional('ENC_BOOT_APP0', encs.get('boot_app0'))
emit_optional('ENC_PARTITIONS', encs.get('partitions'))
emit_optional('ENC_FIRMWARE', encs.get('firmware'))
emit_optional('ENC_SPIFFS', encs.get('spiffs'))
emit_optional('ENC_FACTORY_CFG', encs.get('factory_cfg'))
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
FACTORY_CFG_TEMPLATE_BIN="${RELEASES_DIR}/${ART_FACTORY_CFG}"

ENC_BOOTLOADER_BIN=""
ENC_BOOT_APP0_BIN=""
ENC_PARTITIONS_BIN=""
ENC_FIRMWARE_BIN=""
ENC_SPIFFS_BIN=""
ENC_FACTORY_CFG_BIN=""
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
if [[ -n "${ENC_FACTORY_CFG:-}" ]]; then
  ENC_FACTORY_CFG_BIN="${RELEASES_DIR}/${ENC_FACTORY_CFG}"
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

require_encrypted_artifact() {
  local label="$1"
  local path="$2"
  if [[ -z "${path}" ]]; then
    echo "Error: encrypted artifact for ${label} missing from manifest." >&2
    exit 1
  fi
  if [[ ! -f "${path}" ]]; then
    echo "Error: encrypted artifact for ${label} not found at ${path}." >&2
    exit 1
  fi
}

if [[ "${FLASH_ENCRYPTION_ENABLED}" == "1" ]]; then
  require_encrypted_artifact "bootloader" "${ENC_BOOTLOADER_BIN}"
  require_encrypted_artifact "boot_app0" "${ENC_BOOT_APP0_BIN}"
  require_encrypted_artifact "partitions" "${ENC_PARTITIONS_BIN}"
  require_encrypted_artifact "firmware" "${ENC_FIRMWARE_BIN}"
  require_encrypted_artifact "spiffs" "${ENC_SPIFFS_BIN}"
  require_encrypted_artifact "factory_cfg" "${ENC_FACTORY_CFG_BIN}"

  BOOTLOADER_BIN="${ENC_BOOTLOADER_BIN}"
  BOOT_APP0_BIN="${ENC_BOOT_APP0_BIN}"
  PARTITIONS_BIN="${ENC_PARTITIONS_BIN}"
  FIRMWARE_BIN="${ENC_FIRMWARE_BIN}"
  SPIFFS_BIN="${ENC_SPIFFS_BIN}"
  FACTORY_CFG_TEMPLATE_BIN="${ENC_FACTORY_CFG_BIN}"
  USE_PRE_ENCRYPTED=1
  echo "Using pre-encrypted release bundle for flashing (encryption enabled)."
else
  BOOTLOADER_BIN="$(choose_or_fail "${ENC_BOOTLOADER_BIN}" "${BOOTLOADER_BIN}" "bootloader")"
  BOOT_APP0_BIN="$(choose_or_fail "${ENC_BOOT_APP0_BIN}" "${BOOT_APP0_BIN}" "boot_app0")"
  PARTITIONS_BIN="$(choose_or_fail "${ENC_PARTITIONS_BIN}" "${PARTITIONS_BIN}" "partitions")"
  FIRMWARE_BIN="$(choose_or_fail "${ENC_FIRMWARE_BIN}" "${FIRMWARE_BIN}" "firmware")"
  SPIFFS_BIN="$(choose_or_fail "${ENC_SPIFFS_BIN}" "${SPIFFS_BIN}" "spiffs")"
  FACTORY_CFG_TEMPLATE_BIN="$(choose_or_fail "${ENC_FACTORY_CFG_BIN}" "${FACTORY_CFG_TEMPLATE_BIN}" "factory_cfg")"
  USE_PRE_ENCRYPTED=0
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
  local burn_key_output=""
  if ! burn_key_output="$(printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_key flash_encryption "${FLASH_ENCRYPTION_KEY_FILE}" 2>&1)"; then
    if grep -qi 'read-protected' <<<"${burn_key_output}"; then
      printf '%s\n' "${burn_key_output}"
      echo "Flash encryption key already programmed; skipping burn_key step."
    else
      printf '%s\n' "${burn_key_output}" >&2
      echo "Failed to burn flash encryption key; aborting." >&2
      exit 1
    fi
  else
    printf '%s\n' "${burn_key_output}"
  fi
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_efuse FLASH_CRYPT_CONFIG 0xf
  printf 'BURN\n' | "${ESPEFUSE}" --port "${PORT}" burn_efuse FLASH_CRYPT_CNT 1
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

prepare_factory_payload
if [[ -z "${FACTORY_CFG_FLASH_PATH}" ]]; then
  echo "Error: failed to prepare factory configuration payload." >&2
  exit 1
fi

flash_cmd=(
  "${ESPTOOL}"
  --chip esp32
  --port "${PORT}"
  --baud "${MAIN_HUB_FLASH_BAUD:-921600}"
  --before default-reset
  --after hard-reset
  write-flash
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
  --flash-mode dio
  --flash-freq 40m
  --flash-size detect
  0x1000 "${BOOTLOADER_BIN}"
  0x8000 "${PARTITIONS_BIN}"
  0xe000 "${BOOT_APP0_BIN}"
  0x10000 "${FIRMWARE_BIN}"
  0x290000 "${SPIFFS_BIN}"
  0x3F0000 "${FACTORY_CFG_FLASH_PATH}"
)

print_version_overview() {
  echo "---- Build/Flash Versions ----"
  echo "Flash environment : ${FLASH_ENV_VERSION}"
  echo "Bundle version    : ${BUNDLE_VERSION:-unknown}"
  echo "Bundle commit     : ${BUNDLE_COMMIT:-unknown}"
  echo "Bundle environment: ${BUNDLE_ENVIRONMENT:-unknown}"
  echo "Target serial     : ${SERIAL}"
  echo "------------------------------"
}

ensure_serial_port_ready

if ! verify_flash_plan; then
  echo "Flash plan verification failed; aborting before touching hardware." >&2
  exit 1
fi

print_version_overview
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

  echo "SSID updated. Device will reboot as ${SERIAL}."
  trap - RETURN
  restore_wifi_after_provision
}

if (( WIFI_PROVISION == 1 )); then
  if provision_serial; then
    log_entry "wifi_success"
  else
    echo "Warning: SSID provisioning failed after flash; wiring already updated." >&2
    log_entry "wifi_failed"
  fi
else
  log_entry "wired_only"
fi

echo "Done."
