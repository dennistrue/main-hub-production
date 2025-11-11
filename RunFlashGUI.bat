@echo off
setlocal
cd /d "%~dp0bin"

set PYTHON_BIN=%MAIN_HUB_PYTHON%
if "%PYTHON_BIN%"=="" set PYTHON_BIN=python3

where "%PYTHON_BIN%" >nul 2>nul
if errorlevel 1 (
    set PYTHON_BIN=py
    where "%PYTHON_BIN%" >nul 2>nul
    if errorlevel 1 (
        echo python3 or py was not found. Install Python 3 and try again.
        pause
        exit /b 1
    )
)

"%PYTHON_BIN%" "%~dp0bin\flash_gui.py"
if errorlevel 1 (
    echo Flash GUI exited with an error.
    pause
)
