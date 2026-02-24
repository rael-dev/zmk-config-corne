@echo off
setlocal EnableExtensions EnableDelayedExpansion

if /I "%~1"=="--help" goto :help
if /I "%~1"=="-h" goto :help
if /I "%~1"=="/?" goto :help

cd /d "%~dp0"

echo [1/7] Checking Python...
where python >nul 2>nul
if %errorlevel%==0 (
  set "PY=python"
) else (
  where py >nul 2>nul
  if %errorlevel%==0 (
    set "PY=py -3"
  ) else (
    echo ERROR: Python was not found. Install Python 3.11+ first.
    goto :fail
  )
)

echo [2/7] Upgrading pip...
call :run %PY% -m pip install --upgrade pip
if errorlevel 1 goto :fail

echo [3/7] Installing Python dependencies...
call :run %PY% -m pip install west pyelftools py7zr keymap-drawer "tree-sitter<0.25" "tree-sitter-devicetree<0.15"
if errorlevel 1 goto :fail

echo [4/7] Initializing west workspace if needed...
if not exist ".west" (
  call :run %PY% -m west init -l config
  if errorlevel 1 goto :fail
) else (
  echo .west already exists, skipping west init.
)

echo [5/7] Updating west modules...
call :run %PY% -m west update
if errorlevel 1 goto :fail

echo [6/7] Exporting zephyr CMake package...
call :run %PY% -m west zephyr-export
if errorlevel 1 goto :fail

set "SDK_VERSION=0.16.8"
set "SDK_DIR=%CD%\.tooling\zephyr-sdk-%SDK_VERSION%"
set "SDK_ARCHIVE=%CD%\.tooling\zephyr-sdk-%SDK_VERSION%_windows-x86_64.7z"
set "SDK_URL=https://github.com/zephyrproject-rtos/sdk-ng/releases/download/v%SDK_VERSION%/zephyr-sdk-%SDK_VERSION%_windows-x86_64.7z"

echo [7/7] Ensuring Zephyr SDK v%SDK_VERSION%...
if exist "%SDK_DIR%\setup.cmd" (
  echo SDK already present at "%SDK_DIR%".
) else (
  if not exist ".tooling" mkdir ".tooling"
  if not exist "%SDK_ARCHIVE%" (
    echo Downloading %SDK_URL%
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-WebRequest -Uri '%SDK_URL%' -OutFile '%SDK_ARCHIVE%'"
    if errorlevel 1 goto :fail
  ) else (
    echo SDK archive already downloaded: "%SDK_ARCHIVE%"
  )

  echo Extracting SDK archive...
  call :run %PY% -c "import py7zr; py7zr.SevenZipFile(r'%SDK_ARCHIVE%', mode='r').extractall(r'%CD%\.tooling')"
  if errorlevel 1 goto :fail
)

echo.
echo Setup complete.
echo Build firmware:   build-firmware-clean.bat   or   build-firmware-fast.bat
echo Scripts will use: .tooling\zephyr-sdk-%SDK_VERSION%
goto :eof

:run
echo ^> %*
%*
exit /b %errorlevel%

:help
echo dependencies.bat
echo.
echo Bootstraps local build + draw dependencies for this ZMK repo.
echo.
echo What it does:
echo   1. Installs Python packages: west, pyelftools, py7zr, keymap-drawer
echo   2. Initializes west workspace if .west is missing
echo   3. Runs west update and west zephyr-export
echo   4. Downloads/extracts Zephyr SDK v0.16.8 into .tooling
echo.
echo Usage:
echo   dependencies.bat
echo   dependencies.bat --help
exit /b 0

:fail
echo.
echo Setup failed with exit code %errorlevel%.
pause
exit /b %errorlevel%
