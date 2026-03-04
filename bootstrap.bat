@echo off
setlocal
set SCRIPT_DIR=%~dp0
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%install.ps1" %*
if errorlevel 1 (
  echo.
  echo [bootstrap] 安装失败。
  exit /b 1
)
echo.
echo [bootstrap] 安装完成。
exit /b 0
