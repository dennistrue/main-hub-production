# Main Hub Production

Release artifacts for Main Hub flashing.

## Operator Workflow (GUI)

End-users don’t need to open a terminal. From Finder/Explorer, double-click one of the launchers in the repository root:

- **macOS:** `Run Flash GUI.command`
- **Windows:** `RunFlashGUI.bat`

Both launchers simply `cd bin` and run `flash_gui.py`, so everything the operator needs stays hidden inside the `bin/` directory. Advanced users can still run the Python script manually:

```
python3 flash_gui.py
```

The script starts a tiny local web server, opens your default browser, and prompts for a batch number plus the serial index (001‑100). It automatically derives:

- Serial suffix: `<batch><serial_in_batch padded to 4 digits>`
- SSID: `Main<batch><serial_in_batch padded to 4 digits>`
- Password: looked up from the local password database

Hit **Next** to advance to the next serial within the same batch (up to 100). When you click **Flash**, the GUI spawns `flash_main_hub.sh` on macOS or `flash_main_hub.ps1` on Windows automatically, streams their logs live, and marks the status as **Success**/**Failed** when done.

### One-click launchers

- **macOS:** Double-click `Run Flash GUI.command` (or right-click → *Open* the first time). It just runs `python3 flash_gui.py` inside this folder and pops open the browser.
- **Windows:** Double-click `RunFlashGUI.bat`. The batch file uses `MAIN_HUB_PYTHON`, `python3`, or `py` (in that order) to launch the GUI and keeps the window open if there’s an error.

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

## Distribution to Operators

For hands-off installs, publish a zip of this `main-hub-production` folder (or a GitHub release) and share the download link. Operators only need to:

1. Download and extract the archive (all contents stay in one folder, so they only see the launch scripts and logs).
2. Install Python 3 (plus PowerShell 7 on Windows if desired).
3. Double-click the platform launcher (`Run Flash GUI.command` or `RunFlashGUI.bat`) and follow the on-screen batch/serial workflow.

Because the flashing scripts, tools, and release artifacts all live in this folder—and the GUI already hides the rest—operators never need to open a terminal.

## Script Usage

- **macOS:** `./flash_main_hub.sh --serial 1234 --password softap-pass`
- **Windows:** `pwsh -ExecutionPolicy Bypass -File .\flash_main_hub.ps1 -Serial 1234 -Password softap-pass [-Port COM3] [ -FlashEncryptionKeyFile .\keys\flash_encryption_key.bin ]`

Both scripts derive the factory payload from the provided serial/password, encrypt it when `manifest.json` reports `"flash_encryption": "enabled"`, and log each attempt to `logs/flash_log.csv`.

> Both macOS (`flash_main_hub.sh`) and Windows (`flash_main_hub.ps1`) now bootstrap Python’s `pip` (via `ensurepip`) and install/refresh the `esptool` package automatically when needed, so Python 3 is the only manual prerequisite.
