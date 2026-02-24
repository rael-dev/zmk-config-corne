@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-firmware.ps1" -Pristine 0 %*
set "exit_code=%errorlevel%"
if not "%exit_code%"=="0" (
  echo.
  echo Build failed with exit code %exit_code%.
  pause
)
exit /b %exit_code%
