@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1" %*
if errorlevel 1 (
  echo.
  echo [bootstrap] Install failed.
  exit /b 1
)
echo.
echo [bootstrap] Install completed.
echo [bootstrap] Start command: .\start_8080_toolhub_stack.cmd start
exit /b 0
