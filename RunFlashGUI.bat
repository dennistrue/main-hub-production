@echo off
setlocal EnableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "REPO_DIR=%SCRIPT_DIR%"
rem Trim trailing backslash to avoid escaping the closing quote in git -C
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"
set "BIN_DIR=%SCRIPT_DIR%bin"
set "LOG_DIR=%BIN_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "LOGFILE=%LOG_DIR%\flash_gui_launcher.log"

echo ==== %date% %time% ==== >> "%LOGFILE%"

:log
set "MSG=%~1"
if "%MSG%"=="" (
    echo.
    echo.>>"%LOGFILE%"
) else (
    echo %MSG%
    echo %MSG%>>"%LOGFILE%"
)
goto :eof

call :log "PATH: %PATH%"

:: Ensure Git is available
where git >nul 2>nul
if errorlevel 1 (
    call :log "Git is required but was not found. Please install Git for Windows and rerun."
    pause
    exit /b 1
)

:: Capture current HEAD, fetch/pull, then restart if updated
set "HEAD_BEFORE="
for /f "usebackq delims=" %%H in (`git -C "%REPO_DIR%" rev-parse HEAD 2^>nul`) do set "HEAD_BEFORE=%%H"

call :log "Checking for updates..."
git -C "%REPO_DIR%" fetch --tags --quiet >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :log "git fetch failed. Check network/credentials and retry. See log at %LOGFILE%"
    pause
    exit /b 1
)
git -C "%REPO_DIR%" pull --ff-only >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :log "git pull failed. Resolve Git issues and retry. See log at %LOGFILE%"
    pause
    exit /b 1
)

set "HEAD_AFTER="
for /f "usebackq delims=" %%H in (`git -C "%REPO_DIR%" rev-parse HEAD 2^>nul`) do set "HEAD_AFTER=%%H"

if not "%HEAD_BEFORE%"=="" if not "%HEAD_AFTER%"=="" if not "%HEAD_AFTER%"=="%HEAD_BEFORE%" (
    call :log "Repository updated; restarting launcher to pick up changes..."
    "%~f0" %*
    exit /b
)

cd /d "%BIN_DIR%"

echo Detecting Python...
echo PATH is: %PATH%
set "PYTHON_BIN=%MAIN_HUB_PYTHON%"
if "%PYTHON_BIN%"=="" set "PYTHON_BIN=python3"

call :log "Detecting Python (initial): !PYTHON_BIN!"
where "!PYTHON_BIN!" >nul 2>nul
if errorlevel 1 (
    call :log "!PYTHON_BIN! not found. Trying \"py\"..."
    set "PYTHON_BIN=py"
    where "!PYTHON_BIN!" >nul 2>nul
)

if errorlevel 1 (
    where winget >nul 2>nul
    if errorlevel 1 (
        call :log "Python not found and winget is unavailable. Install Python 3 manually. Log: %LOGFILE%"
        pause
        exit /b 1
    )
    call :log "Python not found. Attempting winget install of Python 3..."
    winget install --id Python.Python.3 -e --source winget >> "%LOGFILE%" 2>&1
    call :log "winget exited with code !errorlevel!"
    call :log "Re-checking for Python after install..."
    set "PYTHON_BIN=python3"
    where "!PYTHON_BIN!" >nul 2>nul
    if errorlevel 1 (
        set "PYTHON_BIN=py"
        where "!PYTHON_BIN!" >nul 2>nul
    )
)

where "!PYTHON_BIN!" >nul 2>nul
if errorlevel 1 (
    call :log "Python is still not available. Install Python 3 (try \"winget install Python.Python.3\") and rerun. Log: %LOGFILE%"
    pause
    exit /b 1
)

call :log "Using Python interpreter: !PYTHON_BIN!"
call :log "Starting GUI in 3 seconds... (Ctrl+C to cancel)"
timeout /t 3 >nul

"!PYTHON_BIN!" "%BIN_DIR%\flash_gui.py" >> "%LOGFILE%" 2>&1
if !errorlevel! neq 0 (
    call :log "Flash GUI exited with an error."
    pause
) else (
    call :log "Flash GUI completed."
    pause
)
endlocal
