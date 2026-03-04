param(
  [switch]$Native
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step {
  param([string]$Message)
  Write-Host "[install] $Message"
}

if ($Native) {
  throw 'This package uses WSL install flow by default. Remove -Native and ensure WSL is installed.'
}

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

Write-Step 'Install completed'
Write-Step 'Start command: ./start_8080_toolhub_stack.sh start'
