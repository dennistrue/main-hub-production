param(
    [Parameter(Mandatory = $true)]
    [string]$Serial,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$Port = $env:MAIN_HUB_SERIAL_PORT,

    [string]$FlashEncryptionKeyFile = "",

    [switch]$SkipSSID
)

$ErrorActionPreference = "Stop"

if (-not $Port) {
    $Port = "COM3"
}

function Show-Usage {
    Write-Host "Usage: .\flash_main_hub.ps1 -Serial <serial> -Password <softap-password> [-Port COM3] [--SkipSSID]" -ForegroundColor Yellow
}

function Require-File([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Required file not found: $Path"
    }
}

function Test-PythonModule {
    param(
        [string]$PythonExe,
        [string]$ModuleName
    )
    $code = "import importlib; importlib.import_module('$ModuleName')"
    & $PythonExe -c $code *> $null
    return $LASTEXITCODE -eq 0
}

function Ensure-Pip([string]$PythonExe) {
    & $PythonExe -m pip --version *> $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        return
    }
    Write-Host "pip not found for $PythonExe; bootstrapping via ensurepip..." -ForegroundColor Yellow
    & $PythonExe -m ensurepip --upgrade
    if ($LASTEXITCODE -ne 0) {
        throw "pip is required but could not be installed automatically. Install pip manually and rerun."
    }
}

function Ensure-PythonModule {
    param(
        [string]$PythonExe,
        [string]$ModuleName,
        [string]$PackageName
    )
    if (Test-PythonModule -PythonExe $PythonExe -ModuleName $ModuleName) {
        return
    }
    Ensure-Pip -PythonExe $PythonExe
    Write-Host "Installing Python package '$PackageName'..." -ForegroundColor Yellow
    & $PythonExe -m pip install --user --upgrade $PackageName
    if ($LASTEXITCODE -ne 0) {
        throw "pip failed to install $PackageName (exit code $LASTEXITCODE). Resolve the issue and rerun."
    }
    if (-not (Test-PythonModule -PythonExe $PythonExe -ModuleName $ModuleName)) {
        throw "Python module '$ModuleName' is still unavailable after installing $PackageName."
    }
}

function Resolve-Python {
    $candidates = @(
        $env:MAIN_HUB_PYTHON,
        "python3",
        "python",
        "py"
    ) | Where-Object { $_ }

    foreach ($candidate in $candidates) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $command) { continue }
        try {
            $version = & $command.Source -c "import sys; print(sys.version_info.major)" 2>$null
            if ($version -ge 3) {
                return $command.Source
            }
        } catch {
            continue
        }
    }

    throw "Unable to locate a Python 3 interpreter. Install Python 3 and make sure it is on PATH."
}

function New-TempFilePath([string]$Prefix) {
    $name = "{0}{1}.bin" -f $Prefix, ([System.Guid]::NewGuid().ToString("N"))
    return Join-Path ([System.IO.Path]::GetTempPath()) $name
}

function Validate-Serial([string]$Value) {
    if (-not $Value -or $Value -notmatch '^[A-Za-z0-9_-]+$') {
        throw "Serial must be alphanumeric and may include _ or -."
    }
}

function Validate-Password([string]$Value) {
    if ($Value.Length -lt 8 -or $Value.Length -gt 63) {
        throw "Password must be between 8 and 63 characters."
    }
    if ($Value.ToCharArray() | Where-Object { [int]$_ -lt 32 -or [int]$_ -gt 126 }) {
        throw "Password must contain printable ASCII characters only."
    }
}

Validate-Serial $Serial
Validate-Password $Password

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReleaseDir = Join-Path $ScriptDir "release"
$ToolsDir = Join-Path (Join-Path $ScriptDir "tools") "esptool"
$FactoryTool = Join-Path (Join-Path $ScriptDir "tools") "gen_factory_payload.py"
$LogDir = Join-Path $ScriptDir "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Require-File $ReleaseDir
Require-File $FactoryTool

$ManifestPath = Join-Path $ReleaseDir "manifest.json"
Require-File $ManifestPath

$Manifest = Get-Content $ManifestPath | ConvertFrom-Json
$Artifacts = $Manifest.artifacts

$Bootloader = Join-Path $ReleaseDir $Artifacts.bootloader
$BootApp0   = Join-Path $ReleaseDir $Artifacts.boot_app0
$Partitions = Join-Path $ReleaseDir $Artifacts.partitions
$Firmware   = Join-Path $ReleaseDir $Artifacts.firmware
$Spiffs     = Join-Path $ReleaseDir $Artifacts.spiffs
$FactoryTemplate = Join-Path $ReleaseDir $Artifacts.factory_cfg

[$Bootloader, $BootApp0, $Partitions, $Firmware, $Spiffs, $FactoryTemplate] | ForEach-Object {
    Require-File $_
}

$HostArch = if ([System.Environment]::Is64BitOperatingSystem -and (Get-CimInstance Win32_Processor).Name -match "ARM") { "windows-arm64" } else { "windows-amd64" }
$EsptoolPath = Join-Path (Join-Path $ToolsDir $HostArch) "esptool.exe"
if (-not (Test-Path $EsptoolPath)) {
    throw "esptool.exe not found at $EsptoolPath"
}

$PythonExe = Resolve-Python
Ensure-PythonModule -PythonExe $PythonExe -ModuleName "esptool.espsecure" -PackageName "esptool"

$FactoryPlainPath = New-TempFilePath "factorycfg_plain_"
$factoryArgs = @(
    $FactoryTool,
    "--serial", $Serial,
    "--password", $Password,
    "--output", $FactoryPlainPath
)
& $PythonExe @factoryArgs

$EncryptionEnabled = $Manifest.flash_encryption -eq "enabled"
$FactoryFlashPath = $FactoryPlainPath
if ($EncryptionEnabled) {
    if (-not $FlashEncryptionKeyFile) {
        $FlashEncryptionKeyFile = Join-Path $ScriptDir "keys/flash_encryption_key.bin"
    }
    Require-File $FlashEncryptionKeyFile
    $FactoryFlashPath = New-TempFilePath "factorycfg_enc_"
    $espsecureArgs = @(
        "-m", "esptool.espsecure",
        "encrypt_flash_data",
        "--keyfile", $FlashEncryptionKeyFile,
        "--address", "0x3F0000",
        "--output", $FactoryFlashPath,
        $FactoryPlainPath
    )
    try {
        & $PythonExe @espsecureArgs
    } catch {
        throw "Failed to encrypt factory payload. Ensure 'esptool' is installed (pip install esptool) so esptool.espsecure is available. Inner error: $_"
    }
}

$UsePreEncrypted = $EncryptionEnabled -or ($FactoryTemplate -like "*.enc.*")
$CompressionArg = if ($UsePreEncrypted) { "--no-compress" } else { "-z" }
$FlashBaud = if ($env:MAIN_HUB_FLASH_BAUD) { $env:MAIN_HUB_FLASH_BAUD } else { "921600" }

$flashArgs = @(
    "--chip", "esp32",
    "--port", $Port,
    "--baud", $FlashBaud,
    "--before", "default_reset",
    "--after", "hard_reset",
    "write_flash",
    $CompressionArg,
    "--flash_mode", "dio",
    "--flash_freq", "40m",
    "--flash_size", "detect",
    "0x1000", $Bootloader,
    "0x8000", $Partitions,
    "0xE000", $BootApp0,
    "0x10000", $Firmware,
    "0x290000", $Spiffs,
    "0x3F0000", $FactoryFlashPath
)

Write-Host "Flashing $($Manifest.version) to $Port" -ForegroundColor Cyan

$flashStatus = "failed"
try {
    & $EsptoolPath @flashArgs
    Write-Host "Flash complete." -ForegroundColor Green
    $flashStatus = "wired_only"
} finally {
    if (Test-Path $FactoryPlainPath) {
        Remove-Item $FactoryPlainPath -ErrorAction SilentlyContinue
    }
    if ($FactoryFlashPath -and (Test-Path $FactoryFlashPath) -and $FactoryFlashPath -ne $FactoryPlainPath) {
        Remove-Item $FactoryFlashPath -ErrorAction SilentlyContinue
    }
    $logLine = "{0},{1},{2},{3}`n" -f (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ"), $Serial, (Split-Path $ReleaseDir -Leaf), $flashStatus
    Add-Content -Path (Join-Path $LogDir "flash_log.csv") -Value $logLine
}

if (-not $SkipSSID) {
    Write-Warning "SSID provisioning not implemented on Windows yet."
}
