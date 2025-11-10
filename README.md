# Main Hub Production

Release artifacts for Main Hub flashing.

## GUI Front End

Run `flash_gui.py` for a minimal cross-platform interface (served in your browser) that wraps the platform-specific flashing scripts:

```
python3 flash_gui.py
```

The script starts a tiny local web server, opens your default browser, and prompts for a batch number plus the serial index (001‑100). It automatically derives:

- Serial suffix: `<batch><serial_in_batch padded to 4 digits>`
- SSID: `Main<batch><serial_in_batch padded to 4 digits>`
- Password: looked up from the local password database

Hit **Next** to advance to the next serial within the same batch (up to 100). When you click **Flash**, the GUI spawns `flash_main_hub.sh` on macOS or `flash_main_hub.ps1` on Windows, streams their logs live, and marks the status as **Success**/**Failed** when done.

Prerequisites:

- Python 3.8+.
- A valid production bundle in `release/` plus the flash-encryption key at `keys/flash_encryption_key.bin`.
- On Windows, install PowerShell 7 (`pwsh`) or ensure Windows PowerShell is on `PATH`. Python dependencies (pip + `esptool`) are auto-installed the first time you run the script.
- `passwords.csv` in this directory (see below) containing the batch/serial/password mapping.

### Password Database

`flash_gui.py` (and the backend API) read passwords from `passwords.csv`, a simple CSV with headers `batch,serial,password`. Entry requirements:

- `serial` must be between 1 and 100 (inclusive) for each batch.
- Passwords must be 8–63 printable ASCII characters.
- Each `(batch, serial)` pair must be unique.

This repo ships with `passwords.csv` pre-populated for **batch 1** (`serial` 1‑100) using placeholder values `B1P0001Pass!` … `B1P0100Pass!`. Add new rows for additional batches before running the GUI; the server refuses to flash units whose batch/serial pair is missing.

## Script Usage

- **macOS:** `./flash_main_hub.sh --serial 1234 --password softap-pass`
- **Windows:** `pwsh -ExecutionPolicy Bypass -File .\flash_main_hub.ps1 -Serial 1234 -Password softap-pass [-Port COM3] [ -FlashEncryptionKeyFile .\keys\flash_encryption_key.bin ]`

Both scripts derive the factory payload from the provided serial/password, encrypt it when `manifest.json` reports `"flash_encryption": "enabled"`, and log each attempt to `logs/flash_log.csv`.

> Both macOS (`flash_main_hub.sh`) and Windows (`flash_main_hub.ps1`) now bootstrap Python’s `pip` (via `ensurepip`) and install/refresh the `esptool` package automatically when needed, so Python 3 is the only manual prerequisite.
