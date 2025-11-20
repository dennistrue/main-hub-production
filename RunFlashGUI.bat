@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "REPO_DIR=%SCRIPT_DIR%"
rem Trim trailing backslash to avoid escaping the closing quote in git -C
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"
set "BIN_DIR=%SCRIPT_DIR%bin"

:: Ensure Git is available
where git >nul 2>nul
if errorlevel 1 (
    echo Git is required but was not found. Install Git for Windows and try again.
    pause
    exit /b 1
)

:: Capture current HEAD, fetch/pull, then restart if updated
set "HEAD_BEFORE="
for /f "usebackq delims=" %%H in (`git -C "%REPO_DIR%" rev-parse HEAD 2^>nul`) do set "HEAD_BEFORE=%%H"

echo Checking for updates...
git -C "%REPO_DIR%" fetch --tags --quiet
if errorlevel 1 (
    echo git fetch failed. Check network/credentials and retry.
    pause
    exit /b 1
)
git -C "%REPO_DIR%" pull --ff-only
if errorlevel 1 (
    echo git pull failed. Resolve Git issues and retry.
    pause
    exit /b 1
)

set "HEAD_AFTER="
for /f "usebackq delims=" %%H in (`git -C "%REPO_DIR%" rev-parse HEAD 2^>nul`) do set "HEAD_AFTER=%%H"

if not "%HEAD_BEFORE%"=="" if not "%HEAD_AFTER%"=="" if not "%HEAD_AFTER%"=="%HEAD_BEFORE%" (
    echo Repository updated; restarting launcher to pick up changes...
    "%~f0" %*
    exit /b
)

cd /d "%BIN_DIR%"

set "PYTHON_BIN=%MAIN_HUB_PYTHON%"
if "%PYTHON_BIN%"=="" set "PYTHON_BIN=python3"

where "%PYTHON_BIN%" >nul 2>nul
if errorlevel 1 (
    echo python3 not found on PATH. Attempting to install via winget...
    winget install --id Python.Python.3 -e --source winget
    set "PYTHON_BIN=py"
    where "%PYTHON_BIN%" >nul 2>nul
    if errorlevel 1 (
        echo Python is still not available. Install Python 3 and rerun.
        pause
        exit /b 1
    )
)

"%PYTHON_BIN%" "%BIN_DIR%\flash_gui.py"
if errorlevel 1 (
    echo Flash GUI exited with an error.
    pause
)
