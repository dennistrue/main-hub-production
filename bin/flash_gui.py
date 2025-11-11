#!/usr/bin/env python3
"""Browser-based GUI for flashing Main Hub bundles."""

from __future__ import annotations

import csv
import http.server
import json
import platform
import re
import shlex
import shutil
import subprocess
import threading
import urllib.parse
import webbrowser
from pathlib import Path
from typing import ClassVar

PRODUCTION_DIR = Path(__file__).resolve().parent
PASSWORD_DB_PATH = PRODUCTION_DIR / "passwords.csv"
SERIAL_MIN = 1
SERIAL_MAX = 100
ANSI_ESCAPE = re.compile(r"\x1B\[[0-9;?]*[ -/]*[@-~]")


class PasswordDatabase:
    def __init__(self, path: Path) -> None:
        self.path = path
        self.entries: dict[tuple[int, int], str] = {}

    def load(self) -> None:
        if not self.path.exists():
            raise SystemExit(
                f"Password database not found at {self.path}. "
                "Create passwords.csv (batch,serial,password)."
            )
        with self.path.open("r", encoding="utf-8", newline="") as fh:
            reader = csv.DictReader(fh)
            required = {"batch", "serial", "password"}
            if not required.issubset(reader.fieldnames or set()):
                raise SystemExit("Password CSV must contain batch,serial,password columns.")
            self.entries = {}
            for row in reader:
                try:
                    batch = int(row["batch"])
                    serial = int(row["serial"])
                except (TypeError, ValueError) as exc:
                    raise SystemExit(f"Invalid batch/serial value in {self.path}: {row}") from exc
                password = row["password"].strip()
                if not (SERIAL_MIN <= serial <= SERIAL_MAX):
                    raise SystemExit(f"Serial {serial} out of supported range {SERIAL_MIN}-{SERIAL_MAX}.")
                if len(password) < 8 or len(password) > 63:
                    raise SystemExit(f"Password for batch {batch} serial {serial} violates length constraints.")
                key = (batch, serial)
                if key in self.entries:
                    raise SystemExit(f"Duplicate password entry for batch {batch} serial {serial:04d}.")
                self.entries[key] = password

    def lookup(self, batch: int, serial: int) -> dict[str, object]:
        if batch <= 0:
            raise ValueError("Batch number must be positive.")
        if not (SERIAL_MIN <= serial <= SERIAL_MAX):
            raise ValueError(f"Serial must be between {SERIAL_MIN} and {SERIAL_MAX}.")
        try:
            password = self.entries[(batch, serial)]
        except KeyError as exc:
            raise ValueError(f"No password entry for batch {batch} serial {serial:04d}.") from exc
        serial_suffix = f"{batch}{serial:04d}"
        ssid = f"Main{serial_suffix}"
        return {
            "batch": batch,
            "serial_number": serial,
            "serial": serial_suffix,
            "ssid": ssid,
            "password": password,
        }


PASSWORD_DB = PasswordDatabase(PASSWORD_DB_PATH)

INDEX_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Main Hub Flasher</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 40px auto; max-width: 720px; color: #1f2933; }
    h1 { font-size: 1.6rem; margin-bottom: 0.2rem; }
    form { display: flex; flex-direction: column; gap: 12px; margin-bottom: 18px; }
    label { font-weight: 600; font-size: 0.95rem; display: block; margin-bottom: 4px; }
    input { padding: 8px; font-size: 1rem; border: 1px solid #c0c9d2; border-radius: 4px; width: 100%; box-sizing: border-box; }
    input[readonly] { background-color: #f8fafc; }
    button { padding: 10px; font-size: 1rem; border: none; border-radius: 4px; background-color: #2563eb; color: #fff; cursor: pointer; }
    button:disabled { background-color: #9ca3af; cursor: not-allowed; }
    .row { display: flex; gap: 12px; flex-wrap: wrap; }
    .row > div { flex: 1; min-width: 160px; }
    .status { font-weight: 600; margin-bottom: 10px; }
    textarea { width: 100%; height: 320px; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; border: 1px solid #c0c9d2; border-radius: 4px; padding: 8px; resize: vertical; box-sizing: border-box; }
    .message { color: #b91c1c; min-height: 1.2rem; }
    .actions { display: flex; gap: 12px; flex-wrap: wrap; }
    .actions button { flex: none; }
  </style>
</head>
<body>
  <h1>Main Hub Flasher</h1>
  <p>Select a batch and serial number (001-100). Passwords are auto-assigned, and the SSID will be <strong>Main&lt;batch&gt;&lt;serial&gt;</strong>.</p>
  <form id="flash-form">
    <div class="row">
      <div>
        <label for="batch">Batch number</label>
        <input id="batch" name="batch" type="number" min="1" value="1" required>
      </div>
      <div>
        <label for="serialNumber">Serial in batch (001-100)</label>
        <input id="serialNumber" name="serialNumber" type="number" min="1" max="100" value="1" required>
      </div>
      <div style="align-self:flex-end;">
        <button type="button" id="next-button">Next</button>
      </div>
    </div>
    <div class="row">
      <div>
        <label for="serialSuffix">Serial suffix</label>
        <input id="serialSuffix" name="serialSuffix" readonly>
      </div>
      <div>
        <label for="ssid">SSID</label>
        <input id="ssid" name="ssid" readonly>
      </div>
      <div>
        <label for="password">Password</label>
        <input id="password" name="password" readonly>
      </div>
    </div>
    <div class="actions">
      <button id="flash-button" type="submit">Flash</button>
    </div>
    <div class="message" id="form-message"></div>
  </form>
  <div class="status">Status: <span id="status">Idle</span></div>
  <textarea id="logs" readonly placeholder="Logs will appear here..."></textarea>

  <script>
    const statusEl = document.getElementById('status');
    const logsEl = document.getElementById('logs');
    const messageEl = document.getElementById('form-message');
    const batchInput = document.getElementById('batch');
    const serialInput = document.getElementById('serialNumber');
    const serialSuffixInput = document.getElementById('serialSuffix');
    const ssidInput = document.getElementById('ssid');
    const passwordInput = document.getElementById('password');
    const form = document.getElementById('flash-form');
    const flashButton = document.getElementById('flash-button');
    const nextButton = document.getElementById('next-button');
    const SERIAL_MIN = 1;
    const SERIAL_MAX = 100;
    let derivedReady = false;

    async function refreshState() {
      try {
        const response = await fetch('/state');
        if (!response.ok) return;
        const data = await response.json();
        statusEl.textContent = data.status;
        logsEl.value = data.logs;
        flashButton.disabled = data.busy || !derivedReady;
      } catch (err) {
        console.error('State poll failed', err);
      }
    }

    async function lookupDerived() {
      const batch = batchInput.value.trim();
      const serial = serialInput.value.trim();
      if (!batch || !serial) {
        derivedReady = false;
        flashButton.disabled = true;
        return;
      }
      try {
        const response = await fetch(`/lookup?batch=${encodeURIComponent(batch)}&serial=${encodeURIComponent(serial)}`);
        const payload = await response.json();
        if (!response.ok || !payload.ok) {
          derivedReady = false;
          flashButton.disabled = true;
          messageEl.textContent = payload.error || 'Lookup failed.';
          serialSuffixInput.value = '';
          ssidInput.value = '';
          passwordInput.value = '';
          return;
        }
        derivedReady = true;
        messageEl.textContent = '';
        serialSuffixInput.value = payload.serial;
        ssidInput.value = payload.ssid;
        passwordInput.value = payload.password;
        flashButton.disabled = false;
      } catch (err) {
        derivedReady = false;
        flashButton.disabled = true;
        messageEl.textContent = 'Lookup request failed. Check the terminal for details.';
      }
    }

    function handleNext() {
      const current = parseInt(serialInput.value, 10) || SERIAL_MIN;
      if (current >= SERIAL_MAX) {
        messageEl.textContent = `Reached serial ${SERIAL_MAX}. Increase the batch number to continue.`;
        return;
      }
      serialInput.value = current + 1;
      lookupDerived();
    }

    async function startFlash(event) {
      event.preventDefault();
      if (!derivedReady) {
        messageEl.textContent = 'Lookup failed; cannot start flash.';
        return;
      }
      messageEl.textContent = '';
      flashButton.disabled = true;
      const params = new URLSearchParams();
      params.set('batch', batchInput.value.trim());
      params.set('serial', serialInput.value.trim());
      try {
        const response = await fetch('/flash', {
          method: 'POST',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
          body: params.toString()
        });
        const payload = await response.json();
        if (!response.ok || !payload.ok) {
          messageEl.textContent = payload.error || 'Unable to start flash.';
          flashButton.disabled = false;
        }
      } catch (err) {
        messageEl.textContent = 'Request failed. Check the terminal for details.';
        flashButton.disabled = false;
      }
    }

    form.addEventListener('submit', startFlash);
    batchInput.addEventListener('change', lookupDerived);
    serialInput.addEventListener('change', lookupDerived);
    serialInput.addEventListener('input', () => { derivedReady = false; flashButton.disabled = true; });
    batchInput.addEventListener('input', () => { derivedReady = false; flashButton.disabled = true; });
    nextButton.addEventListener('click', handleNext);
    setInterval(refreshState, 1000);
    lookupDerived();
    refreshState();
  </script>
</body>
</html>
"""


def load_password_db() -> None:
    PASSWORD_DB.load()


def build_flash_command(serial: str, password: str) -> tuple[list[str], Path]:
    system = platform.system()
    if system == "Darwin":
        script = PRODUCTION_DIR / "flash_main_hub.sh"
        if not script.exists():
            raise FileNotFoundError(f"macOS script not found: {script}")
        return ["/bin/bash", str(script), "--serial", serial, "--password", password], PRODUCTION_DIR
    if system == "Windows":
        script = PRODUCTION_DIR / "flash_main_hub.ps1"
        if not script.exists():
            raise FileNotFoundError(f"PowerShell script not found: {script}")
        shell = find_powershell()
        command = [
            shell,
            "-NoLogo",
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(script),
            "-Serial",
            serial,
            "-Password",
            password,
        ]
        return command, PRODUCTION_DIR
    raise RuntimeError(f"Unsupported operating system: {system}")


def find_powershell() -> str:
    for candidate in ("pwsh", "powershell"):
        path = shutil.which(candidate)
        if path:
            return path
    raise FileNotFoundError("Neither pwsh nor powershell was found on PATH.")


class FlashManager:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._busy = False
        self._status = "Idle"
        self._logs: list[str] = []
        self._max_lines = 600

    def start(self, batch: int, serial: int) -> tuple[bool, str]:
        try:
            unit = PASSWORD_DB.lookup(batch, serial)
        except ValueError as exc:
            return False, str(exc)

        with self._lock:
            if self._busy:
                return False, "Flash already in progress."
            self._busy = True
            self._status = f"Flashing {unit['serial']}..."
            self._logs = [
                f"Starting flash for batch {batch} serial {serial:04d}",
                f"SSID: {unit['ssid']}",
            ]

        thread = threading.Thread(target=self._run_flash, args=(unit,), daemon=True)
        thread.start()
        return True, "Flash started."

    def _append_log(self, message: str) -> None:
        sanitized = ANSI_ESCAPE.sub("", message.replace("\r", ""))
        with self._lock:
            self._logs.append(sanitized)
            if len(self._logs) > self._max_lines:
                self._logs = self._logs[-self._max_lines :]

    def _run_flash(self, unit: dict[str, object]) -> None:
        success = False
        serial_suffix = str(unit["serial"])
        password = str(unit["password"])
        try:
            command, workdir = build_flash_command(serial_suffix, password)
            command_display = " ".join(shlex.quote(part) for part in command[:-1] + ["******"])
            self._append_log(f"Command: {command_display}")
            process = subprocess.Popen(
                command,
                cwd=str(workdir),
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            assert process.stdout is not None
            for line in process.stdout:
                self._append_log(line.rstrip())
            success = process.wait() == 0
        except FileNotFoundError as exc:
            self._append_log(f"Error: {exc}")
        except Exception as exc:  # noqa: BLE001
            self._append_log(f"Error launching flash: {exc}")
        finally:
            final_message = "Flash completed successfully." if success else "Flash failed. Check above logs."
            with self._lock:
                self._busy = False
                self._status = "Success" if success else "Failed"
            self._append_log(final_message)

    def state(self) -> dict[str, object]:
        with self._lock:
            return {
                "status": self._status,
                "busy": self._busy,
                "logs": "\n".join(self._logs),
            }


class FlashRequestHandler(http.server.BaseHTTPRequestHandler):
    manager: ClassVar[FlashManager]

    def do_GET(self) -> None:
        if self.path == "/" or self.path.startswith("/?"):
            self._send_response(200, INDEX_HTML.encode("utf-8"), "text/html; charset=utf-8")
        elif self.path.startswith("/state"):
            payload = json.dumps(self.manager.state()).encode("utf-8")
            self._send_response(200, payload, "application/json")
        elif self.path.startswith("/lookup"):
            self._handle_lookup()
        else:
            self.send_error(404, "Not found")

    def do_POST(self) -> None:
        if self.path != "/flash":
            self.send_error(404, "Not found")
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        data = urllib.parse.parse_qs(body)
        try:
            batch = int(data.get("batch", [""])[0])
            serial = int(data.get("serial", [""])[0])
        except (TypeError, ValueError):
            self._json_response({"ok": False, "error": "Batch and serial must be integers."}, status=400)
            return

        ok, message = self.manager.start(batch, serial)
        status_code = 200 if ok else 400
        payload = {"ok": ok}
        if not ok:
            payload["error"] = message
        self._json_response(payload, status=status_code)

    def _handle_lookup(self) -> None:
        query = urllib.parse.urlparse(self.path).query
        params = urllib.parse.parse_qs(query)
        try:
            batch = int(params.get("batch", [""])[0])
            serial = int(params.get("serial", [""])[0])
            unit = PASSWORD_DB.lookup(batch, serial)
        except (ValueError, TypeError) as exc:
            self._json_response({"ok": False, "error": str(exc)}, status=400)
            return
        self._json_response({"ok": True, **unit})

    def _json_response(self, payload: dict[str, object], status: int = 200) -> None:
        body = json.dumps(payload).encode("utf-8")
        self._send_response(status, body, "application/json")

    def _send_response(self, status: int, body: bytes, content_type: str) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:  # noqa: A003
        return


def run_server() -> None:
    load_password_db()
    manager = FlashManager()
    FlashRequestHandler.manager = manager
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FlashRequestHandler)
    host, port = server.server_address
    url = f"http://{host}:{port}/"
    print(f"Main Hub flasher listening on {url}")
    try:
        webbrowser.open(url, new=2)
    except Exception:  # noqa: BLE001
        print("Opening the browser failed automatically; open the URL above manually.")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping server...")
    finally:
        server.shutdown()


def main() -> None:
    run_server()


if __name__ == "__main__":
    main()
