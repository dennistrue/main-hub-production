param(
    [Parameter(Mandatory = $true)]
    [string]$Serial,

    [string]$Port = "COM3",

    [switch]$SkipSSID
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    Write-Host "Usage: .\flash_main_hub.ps1 -Serial <serial> [-Port COM3] [--SkipSSID]" -ForegroundColor Yellow
}

function Require-File([string]$Path) {
    if (-not (Test-Path $Path)) {
        throw "Required file not found: $Path"
    }
}

if (-not $Serial -or $Serial -notmatch '^[A-Za-z0-9_-]+$') {
    Show-Usage
    throw "Serial must be alphanumeric and may include _ or -."
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReleaseDir = Join-Path $ScriptDir "release"
$ToolsDir = Join-Path $ScriptDir "tools" | Join-Path -ChildPath "esptool"
$LogDir = Join-Path $ScriptDir "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

Require-File $ReleaseDir

$ManifestPath = Join-Path $ReleaseDir "manifest.json"
Require-File $ManifestPath

$Manifest = Get-Content $ManifestPath | ConvertFrom-Json
$Artifacts = $Manifest.artifacts

$Bootloader = Join-Path $ReleaseDir $Artifacts.bootloader
$BootApp0   = Join-Path $ReleaseDir $Artifacts.boot_app0
$Partitions = Join-Path $ReleaseDir $Artifacts.partitions
$Firmware   = Join-Path $ReleaseDir $Artifacts.firmware
$Spiffs     = Join-Path $ReleaseDir $Artifacts.spiffs

[$Bootloader, $BootApp0, $Partitions, $Firmware, $Spiffs] | ForEach-Object {
    Require-File $_
}

$HostArch = if ([System.Environment]::Is64BitOperatingSystem -and (Get-CimInstance Win32_Processor).Name -match "ARM") { "windows-arm64" } else { "windows-amd64" }
$EsptoolPath = Join-Path (Join-Path $ToolsDir $HostArch) "esptool.exe"
if (-not (Test-Path $EsptoolPath)) {
    throw "esptool.exe not found at $EsptoolPath"
}

Write-Host "Flashing $($Manifest.version) to $Port" -ForegroundColor Cyan

& $EsptoolPath --chip esp32 --port $Port --baud 921600 --before default_reset --after hard_reset `
    write_flash -z --flash_mode dio --flash_freq 40m --flash_size detect `
    0x1000 $Bootloader `
    0x8000 $Partitions `
    0xE000 $BootApp0 `
    0x10000 $Firmware `
    0x290000 $Spiffs

if (-not $SkipSSID) {
    Write-Warning "SSID provisioning not implemented on Windows yet."
}

Write-Host "Flash complete." -ForegroundColor Green
