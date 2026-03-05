param(
  [switch]$Wsl
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$WinInstaller = Join-Path $ScriptDir 'install.win.ps1'

function Write-Step {
  param([string]$Message)
  Write-Host "[install] $Message"
}

function Invoke-WslInstaller {
  if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
    throw 'wsl.exe not found. Please install WSL first.'
  }
  Write-Step "Run install.sh inside WSL"
  $WslDir = (& wsl.exe wslpath -a "$ScriptDir").Trim()
  if ([string]::IsNullOrWhiteSpace($WslDir)) {
    throw 'Cannot convert current directory to a WSL path.'
  }
  $Cmd = "cd '$WslDir' && ./install.sh"
  & wsl.exe bash -lc $Cmd
  if ($LASTEXITCODE -ne 0) {
    throw "Install failed, exit code: $LASTEXITCODE"
  }
  Write-Step 'Install completed (WSL)'
  Write-Step 'Start command: ./start_8080_toolhub_stack.sh start'
}

function Invoke-WinInstaller {
  if (-not (Test-Path $WinInstaller)) {
    throw "Windows installer not found: $WinInstaller"
  }
  Write-Step 'Run install.win.ps1'
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $WinInstaller
  if ($LASTEXITCODE -ne 0) {
    throw "Windows install failed, exit code: $LASTEXITCODE"
  }
  Write-Step 'Install completed (Windows)'
  Write-Step 'Start command: .\start_8080_toolhub_stack.cmd start'
}

if ($Wsl) {
  Invoke-WslInstaller
} else {
  Invoke-WinInstaller
}
