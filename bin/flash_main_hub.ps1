param(
    [Parameter(Mandatory = $true)]
    [string]$Serial,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$Port = $env:MAIN_HUB_SERIAL_PORT,

    [string]$FlashEncryptionKeyFile = "",

    [switch]$WifiProvision,

    [switch]$SkipSSID
)

$ErrorActionPreference = "Stop"

function Show-Usage {
    Write-Host "Usage: .\flash_main_hub.ps1 -Serial <serial> -Password <softap-password> [-Port COMx|auto] [-WifiProvision]" -ForegroundColor Yellow
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

function Sanitize-Serial([string]$Value) {
    $filtered = ($Value.ToCharArray() | Where-Object { $_ -match '[A-Za-z0-9_-]' }) -join ''
    if (-not $filtered) {
        throw "Serial suffix must retain at least one valid character after sanitization."
    }
    if ($filtered.Length -gt 28) {
        $filtered = $filtered.Substring(0, 28)
    }
    return $filtered
}

function Get-SerialPorts {
    $ports = @()
    try {
        $ports = Get-CimInstance Win32_SerialPort -ErrorAction Stop | ForEach-Object { $_.DeviceID }
    } catch {
        try {
            $ports = Get-WmiObject Win32_SerialPort -ErrorAction Stop | ForEach-Object { $_.DeviceID }
        } catch {
            $ports = @()
        }
    }
    if (-not $ports -or $ports.Count -eq 0) {
        $fallback = @()
        foreach ($n in 1..30) {
            $fallback += "COM$n"
        }
        $ports = $fallback
    }
    return ($ports | Where-Object { $_ -match '^COM\d+$' } | Sort-Object -Unique)
}

function Auto-SelectPort {
    $ports = Get-SerialPorts
    if (-not $ports -or $ports.Count -eq 0) {
        throw "No serial ports detected. Connect a board or pass -Port explicitly."
    }
    if ($ports.Count -eq 1) {
        Write-Host "Auto-selected serial port $($ports[0])" -ForegroundColor Cyan
        return $ports[0]
    }
    Write-Warning ("Multiple serial ports detected: {0}. Using {1}. Specify -Port to override." -f ($ports -join ", "), $ports[0])
    return $ports[0]
}

function Assert-PortAvailable([string]$PortPath) {
    try {
        $sp = New-Object System.IO.Ports.SerialPort $PortPath, 115200
        $sp.Open()
        $sp.Close()
    } catch {
        throw "Serial port $PortPath is unavailable or busy: $_"
    }
}

Validate-Serial $Serial
Validate-Password $Password
$SanitizedSerial = Sanitize-Serial $Serial
if ($SanitizedSerial -ne $Serial) {
    Write-Host "Serial sanitized to '$SanitizedSerial' for factory config." -ForegroundColor Yellow
}
$Serial = $SanitizedSerial

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ReleaseDir = Join-Path $ScriptDir "release"
$ToolsDir = Join-Path (Join-Path $ScriptDir "tools") "esptool"
$FactoryTool = Join-Path (Join-Path $ScriptDir "tools") "gen_factory_payload.py"
$LogDir = Join-Path $ScriptDir "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null

if (-not $FlashEncryptionKeyFile -or $FlashEncryptionKeyFile -eq "") {
    $FlashEncryptionKeyFile = Join-Path $ScriptDir "keys/flash_encryption_key.bin"
}
Require-File $FlashEncryptionKeyFile

Require-File $ReleaseDir
Require-File $FactoryTool

if (-not $Port -or $Port -eq "") { $Port = "auto" }
if ($Port -eq "auto") {
    $Port = Auto-SelectPort
}
Assert-PortAvailable $Port
$DeprecatedSkip = $SkipSSID.IsPresent
if ($DeprecatedSkip) {
    Write-Warning "SkipSSID is deprecated; Wi-Fi provisioning is off by default. Use -WifiProvision to enable."
}
$DoWifiProvision = $WifiProvision.IsPresent

$ManifestPath = Join-Path $ReleaseDir "manifest.json"
Require-File $ManifestPath

$Manifest = Get-Content $ManifestPath | ConvertFrom-Json
$Artifacts = $Manifest.artifacts
$EncArtifacts = $Manifest.encrypted_artifacts
$EncryptionEnabled = $Manifest.flash_encryption -eq "enabled"

function Resolve-EncPath([string]$RelPath) {
    if (-not $RelPath) { return $null }
    return (Join-Path $ReleaseDir $RelPath)
}

$BootloaderPlain = Join-Path $ReleaseDir $Artifacts.bootloader
$BootApp0Plain   = Join-Path $ReleaseDir $Artifacts.boot_app0
$PartitionsPlain = Join-Path $ReleaseDir $Artifacts.partitions
$FirmwarePlain   = Join-Path $ReleaseDir $Artifacts.firmware
$SpiffsPlain     = Join-Path $ReleaseDir $Artifacts.spiffs
$FactoryTemplatePlain = Join-Path $ReleaseDir $Artifacts.factory_cfg

$BootloaderEnc = Resolve-EncPath $EncArtifacts.bootloader
$BootApp0Enc   = Resolve-EncPath $EncArtifacts.boot_app0
$PartitionsEnc = Resolve-EncPath $EncArtifacts.partitions
$FirmwareEnc   = Resolve-EncPath $EncArtifacts.firmware
$SpiffsEnc     = Resolve-EncPath $EncArtifacts.spiffs
$FactoryTemplateEnc = Resolve-EncPath $EncArtifacts.factory_cfg

function Select-Artifact {
    param(
        [string]$Label,
        [string]$PlainPath,
        [string]$EncPath,
        [bool]$RequireEncrypted
    )

    if ($RequireEncrypted) {
        if (-not $EncPath) { throw "Encrypted artifact for $Label missing from manifest while flash_encryption=enabled." }
        Require-File $EncPath
        return $EncPath
    }

    if ($EncPath) {
        Require-File $EncPath
        return $EncPath
    }

    Require-File $PlainPath
    return $PlainPath
}

$UsePreEncrypted = $false
$RequireEncrypted = $EncryptionEnabled

$Bootloader = Select-Artifact -Label "bootloader" -PlainPath $BootloaderPlain -EncPath $BootloaderEnc -RequireEncrypted $RequireEncrypted
$UsePreEncrypted = $UsePreEncrypted -or ($Bootloader -eq $BootloaderEnc)
$BootApp0   = Select-Artifact -Label "boot_app0" -PlainPath $BootApp0Plain -EncPath $BootApp0Enc -RequireEncrypted $RequireEncrypted
$UsePreEncrypted = $UsePreEncrypted -or ($BootApp0 -eq $BootApp0Enc)
$Partitions = Select-Artifact -Label "partitions" -PlainPath $PartitionsPlain -EncPath $PartitionsEnc -RequireEncrypted $RequireEncrypted
$UsePreEncrypted = $UsePreEncrypted -or ($Partitions -eq $PartitionsEnc)
$Firmware   = Select-Artifact -Label "firmware" -PlainPath $FirmwarePlain -EncPath $FirmwareEnc -RequireEncrypted $RequireEncrypted
$UsePreEncrypted = $UsePreEncrypted -or ($Firmware -eq $FirmwareEnc)
$Spiffs     = Select-Artifact -Label "spiffs" -PlainPath $SpiffsPlain -EncPath $SpiffsEnc -RequireEncrypted $RequireEncrypted
$UsePreEncrypted = $UsePreEncrypted -or ($Spiffs -eq $SpiffsEnc)
$FactoryTemplate = Select-Artifact -Label "factory_cfg" -PlainPath $FactoryTemplatePlain -EncPath $FactoryTemplateEnc -RequireEncrypted $RequireEncrypted
$UsePreEncrypted = $UsePreEncrypted -or ($FactoryTemplate -eq $FactoryTemplateEnc)

$PreferredArch = if ([System.Environment]::Is64BitOperatingSystem -and (Get-CimInstance Win32_Processor).Name -match "ARM") { "windows-arm64" } else { "windows-amd64" }
$FallbackArch = if ($PreferredArch -eq "windows-arm64") { "windows-amd64" } else { "windows-arm64" }

function Resolve-ToolPath {
    param(
        [string]$Arch,
        [string]$ToolName
    )
    $candidate = Join-Path (Join-Path $ToolsDir $Arch) $ToolName
    if (Test-Path $candidate) { return $candidate }
    return $null
}

function Select-ToolBinaries {
    param(
        [string]$Preferred,
        [string]$Fallback
    )
    $esptool = Resolve-ToolPath -Arch $Preferred -ToolName "esptool.exe"
    $espefuse = Resolve-ToolPath -Arch $Preferred -ToolName "espefuse.exe"
    $espsecure = Resolve-ToolPath -Arch $Preferred -ToolName "espsecure.exe"

    $chosenArch = $Preferred
    if (-not $esptool -or -not $espefuse -or -not $espsecure) {
        Write-Warning ("Preferred toolchain '{0}' missing pieces; falling back to '{1}'." -f $Preferred, $Fallback)
        $esptool = Resolve-ToolPath -Arch $Fallback -ToolName "esptool.exe"
        $espefuse = Resolve-ToolPath -Arch $Fallback -ToolName "espefuse.exe"
        $espsecure = Resolve-ToolPath -Arch $Fallback -ToolName "espsecure.exe"
        $chosenArch = $Fallback
    }

    if (-not $esptool) { throw "esptool.exe not found in $Preferred or $Fallback toolchains." }
    if (-not $espefuse) { throw "espefuse.exe not found in $Preferred or $Fallback toolchains." }
    if (-not $espsecure) { throw "espsecure.exe not found in $Preferred or $Fallback toolchains." }

    return @{
        Arch      = $chosenArch
        Esptool   = $esptool
        Espefuse  = $espefuse
        Espsecure = $espsecure
    }
}

$Tools = Select-ToolBinaries -Preferred $PreferredArch -Fallback $FallbackArch
$HostArch = $Tools.Arch
$EsptoolPath = $Tools.Esptool
$EspefusePath = $Tools.Espefuse
$EspsecurePath = $Tools.Espsecure

$PythonExe = Resolve-Python

$FactoryPlainPath = New-TempFilePath "factorycfg_plain_"
$factoryArgs = @(
    $FactoryTool,
    "--serial", $Serial,
    "--password", $Password,
    "--output", $FactoryPlainPath
)
& $PythonExe @factoryArgs

$FactoryFlashPath = $FactoryPlainPath
if ($EncryptionEnabled) {
    $FactoryFlashPath = New-TempFilePath "factorycfg_enc_"
    $espsecureArgs = @(
        "encrypt_flash_data",
        "--keyfile", $FlashEncryptionKeyFile,
        "--address", "0x3F0000",
        "--output", $FactoryFlashPath,
        $FactoryPlainPath
    )
    & $EspsecurePath @espsecureArgs
}

$CompressionArg = if ($UsePreEncrypted -or $EncryptionEnabled) { "--no-compress" } else { "-z" }
$FlashBaud = if ($env:MAIN_HUB_FLASH_BAUD) { $env:MAIN_HUB_FLASH_BAUD } else { "921600" }

function Get-EfuseSummary {
    param([int]$Retries = 3)
    $attempt = 0
    do {
        try {
            $output = & $EspefusePath --port $Port summary 2>&1
            return $output
        } catch {
            $attempt++
            if ($attempt -ge $Retries) { throw "espefuse summary failed after $Retries attempts: $_" }
            Start-Sleep -Seconds 1
        }
    } while ($true)
}

function Needs-FlashEncryptionSetup {
    $summary = Get-EfuseSummary
    $line = ($summary -split "`n" | Where-Object { $_ -match 'FLASH_CRYPT_CNT' }) -join ''
    return ($line -match "= 0")
}

function Burn-FlashEncryption {
    Write-Host "Burning flash encryption key and eFuses..." -ForegroundColor Cyan
    $burnOutput = ""
    try {
        $burnOutput = (echo BURN | & $EspefusePath --port $Port burn_key flash_encryption $FlashEncryptionKeyFile 2>&1)
        Write-Host $burnOutput
    } catch {
        if ($burnOutput -match 'read-protected') {
            Write-Host $burnOutput
            Write-Host "Flash encryption key already programmed; skipping burn_key step."
        } else {
            throw "Failed to burn flash encryption key: $_"
        }
    }

    echo BURN | & $EspefusePath --port $Port burn_efuse FLASH_CRYPT_CONFIG 0xf
    echo BURN | & $EspefusePath --port $Port burn_efuse FLASH_CRYPT_CNT 1
    echo BURN | & $EspefusePath --port $Port burn_efuse DISABLE_DL_DECRYPT 1
    echo BURN | & $EspefusePath --port $Port burn_efuse DISABLE_DL_CACHE 1
    Write-Host "Flash encryption eFuses programmed." -ForegroundColor Green
}

if ($EncryptionEnabled) {
    if (Needs-FlashEncryptionSetup) {
        Burn-FlashEncryption
    } else {
        Write-Host "Flash encryption already enabled on target."
    }
}

function Verify-FlashPlan {
    param([array]$Regions)
    $ok = $true
    Write-Host "Verifying flash layout and region sizes..."
    foreach ($r in $Regions) {
        $path = $r.Path
        if (-not (Test-Path $path)) {
            Write-Host "Verification error: missing file $path" -ForegroundColor Red
            $ok = $false
            continue
        }
        $size = (Get-Item $path).Length
        $limit = [int64]$r.Limit
        Write-Host ("  {0,-11} {1,10} bytes (limit {2})" -f $r.Name, $size, $limit)
        if ($size -gt $limit) {
            Write-Host "Verification error: $($r.Name) exceeds allocated size." -ForegroundColor Red
            $ok = $false
        }
    }
    if (-not $ok) { throw "Flash plan validation failed." }
}

Verify-FlashPlan -Regions @(
    @{ Name = "bootloader";  Path = $Bootloader;       Limit = 0x7000 },
    @{ Name = "partitions";  Path = $Partitions;       Limit = 0x1000 },
    @{ Name = "boot_app0";   Path = $BootApp0;         Limit = 0x2000 },
    @{ Name = "firmware";    Path = $Firmware;         Limit = 0x140000 },
    @{ Name = "spiffs";      Path = $Spiffs;           Limit = 0x160000 },
    @{ Name = "factory_cfg"; Path = $FactoryFlashPath; Limit = 0x10000 }
)

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

if ($DoWifiProvision) {
    Write-Warning "Wi-Fi provisioning is not implemented on Windows yet."
}
