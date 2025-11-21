@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "REPO_DIR=%SCRIPT_DIR%"
rem Trim trailing backslash to avoid escaping the closing quote in git -C
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"
set "BIN_DIR=%SCRIPT_DIR%bin"
set "LOG_DIR=%BIN_DIR%\logs"
if not exist "%LOG_DIR%" mkdir "%LOG_DIR%" >nul 2>&1
set "RUN_ID=%date:/=%_%time::=%"
set "RUN_ID=%RUN_ID: =%"
set "RUN_ID=%RUN_ID:.=%"
set "LOGFILE=%LOG_DIR%\flash_gui_launcher_%RUN_ID%.log"

echo ==== %date% %time% ==== >> "%LOGFILE%"

setlocal enabledelayedexpansion
goto :main
:log
echo %~1
echo %~1 >> "%LOGFILE%"
goto :eof

:main
call :log "PATH: %PATH%"

:: Ensure Git is available
where git >nul 2>nul
if errorlevel 1 (
    call :log "Git is required but was not found. Please install Git for Windows and rerun."
    exit /b 1
)

:: Capture current HEAD, fetch/pull, then restart if updated
set "HEAD_BEFORE="
for /f "usebackq delims=" %%H in (`git -C "%REPO_DIR%" rev-parse HEAD 2^>nul`) do set "HEAD_BEFORE=%%H"

call :log "Checking for updates..."
git -C "%REPO_DIR%" fetch --tags --quiet >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :log "git fetch failed. Check network/credentials and retry. See log at %LOGFILE%"
    exit /b 1
)
git -C "%REPO_DIR%" pull --ff-only >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :log "git pull failed. Resolve Git issues and retry. See log at %LOGFILE%"
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
if "%PYTHON_BIN%"=="" set "PYTHON_BIN=python"

call :log "Detecting Python (initial): %PYTHON_BIN%"
where "%PYTHON_BIN%" >nul 2>nul
if errorlevel 1 (
    call :log "%PYTHON_BIN% not found. Trying \"py\"..."
    set "PYTHON_BIN=py"
    where "%PYTHON_BIN%" >nul 2>nul
)

if errorlevel 1 (
    call :log "%PYTHON_BIN% not found. Trying \"python3\"..."
    set "PYTHON_BIN=python3"
    where "%PYTHON_BIN%" >nul 2>nul
)

call :log "Validating Python with --version"
"%PYTHON_BIN%" --version >nul 2>nul
if errorlevel 1 (
    call :log "%PYTHON_BIN% failed; attempting winget install of Python 3.13..."
    winget install --id Python.Python.3.13 -e --source winget --accept-source-agreements --accept-package-agreements >> "%LOGFILE%" 2>&1
    call :log "winget exited with code %errorlevel%"
    call :log "Re-checking for Python after install..."
    for %%P in (python py python3) do (
        where "%%P" >nul 2>nul
        if not errorlevel 1 (
            "%%P" --version >nul 2>nul
            if not errorlevel 1 (
                set "PYTHON_BIN=%%P"
                goto :found_python
            )
        )
    )
    call :log "Python is still not available. Install Python 3 (try \"winget install Python.Python.3.13\") and rerun. Log: %LOGFILE%"
    exit /b 1
)

:found_python
where "%PYTHON_BIN%" >nul 2>nul
if errorlevel 1 (
    call :log "Python is still not available. Install Python 3 (try \"winget install Python.Python.3.13\") and rerun. Log: %LOGFILE%"
    exit /b 1
)
"%PYTHON_BIN%" --version >nul 2>nul
if errorlevel 1 (
    call :log "Python is present on PATH but failed to run. Install Python 3 (try \"winget install Python.Python.3.13\") and rerun. Log: %LOGFILE%"
    exit /b 1
)

call :log "Using Python interpreter: %PYTHON_BIN%"
call :log "Starting GUI in 3 seconds... (Ctrl+C to cancel)"
timeout /t 3 >nul

"%PYTHON_BIN%" "%BIN_DIR%\flash_gui.py" >> "%LOGFILE%" 2>&1
if errorlevel 1 (
    call :log "Flash GUI exited with an error."
) else (
    call :log "Flash GUI completed."
)
