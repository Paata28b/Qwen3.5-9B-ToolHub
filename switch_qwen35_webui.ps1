param(
    [string]$Command = 'status',
    [string]$ThinkMode = 'think-on'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path $ScriptDir).Path
$BinPath = if ($env:BIN_PATH) { $env:BIN_PATH } else { Join-Path $RootDir '.tmp\llama_win_cuda\llama-server.exe' }
$HostAddr = if ($env:HOST) { $env:HOST } else { '127.0.0.1' }
$PortNum = if ($env:PORT) { $env:PORT } else { '8080' }
$CtxSize = if ($env:CTX_SIZE) { $env:CTX_SIZE } else { '16384' }
$ImageMinTokens = if ($env:IMAGE_MIN_TOKENS) { $env:IMAGE_MIN_TOKENS } else { '256' }
$ImageMaxTokens = if ($env:IMAGE_MAX_TOKENS) { $env:IMAGE_MAX_TOKENS } else { '1024' }
$MmprojOffload = if ($env:MMPROJ_OFFLOAD) { $env:MMPROJ_OFFLOAD } else { 'off' }
$ModelPath = if ($env:MODEL_PATH) { $env:MODEL_PATH } else { Join-Path $RootDir '.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\Qwen3.5-9B-Q4_K_M.gguf' }
$MmprojPath = if ($env:MMPROJ_PATH) { $env:MMPROJ_PATH } else { Join-Path $RootDir '.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF\mmproj-Qwen3.5-9B-BF16.gguf' }
$WebuiDir = Join-Path $RootDir '.tmp\webui'
$PidFile = Join-Path $WebuiDir 'llama_server.pid'
$CurrentLogFile = Join-Path $WebuiDir 'current.log'

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Test-Health {
    try {
        $null = Invoke-RestMethod -Uri "http://$HostAddr`:$PortNum/health" -Method Get -TimeoutSec 2
        return $true
    } catch {
        return $false
    }
}

function Get-ModelId {
    try {
        $models = Invoke-RestMethod -Uri "http://$HostAddr`:$PortNum/v1/models" -Method Get -TimeoutSec 3
        if ($models.data -and $models.data.Count -gt 0) {
            return [string]$models.data[0].id
        }
        return ''
    } catch {
        return ''
    }
}

function Wait-Ready {
    for ($i = 0; $i -lt 60; $i++) {
        if (Test-Health) {
            $modelId = Get-ModelId
            if (-not [string]::IsNullOrWhiteSpace($modelId)) {
                return $true
            }
        }
        Start-Sleep -Seconds 1
    }
    return $false
}

function Stop-Server {
    if (Test-Path $PidFile) {
        $raw = Get-Content -Path $PidFile -ErrorAction SilentlyContinue | Select-Object -First 1
        $pid = 0
        if ([int]::TryParse([string]$raw, [ref]$pid) -and $pid -gt 0) {
            try {
                Stop-Process -Id $pid -Force -ErrorAction SilentlyContinue
            } catch {}
        }
    }

    $procs = Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue
    if ($procs) {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    if (Test-Path $PidFile) {
        Remove-Item -Path $PidFile -Force -ErrorAction SilentlyContinue
    }
}

function Show-Status {
    if (Test-Health) {
        $modelId = Get-ModelId
        if ([string]::IsNullOrWhiteSpace($modelId)) {
            $modelId = 'loading'
        }
        Write-Host '状态: 运行中'
        Write-Host "地址: http://$HostAddr`:$PortNum"
        Write-Host "模型: $modelId"
        if (Test-Path $CurrentLogFile) {
            $p = Get-Content -Path $CurrentLogFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($p) {
                Write-Host "日志: $p"
            }
        }
        return
    }
    Write-Host '状态: 未运行'
}

function Resolve-RuntimeProfile {
    switch ($ThinkMode) {
        'think-on' { return @{ ReasoningBudget = '-1'; MaxTokens = '-1' } }
        'think-off' { return @{ ReasoningBudget = '0'; MaxTokens = '2048' } }
        default { throw "不支持的思考模式: $ThinkMode" }
    }
}

function Validate-Limits {
    if (($CtxSize -notmatch '^[0-9]+$') -or ($ImageMinTokens -notmatch '^[0-9]+$') -or ($ImageMaxTokens -notmatch '^[0-9]+$')) {
        throw 'CTX_SIZE / IMAGE_MIN_TOKENS / IMAGE_MAX_TOKENS 必须是正整数'
    }
    if ([int]$CtxSize -le 0 -or [int]$ImageMinTokens -le 0 -or [int]$ImageMaxTokens -le 0) {
        throw 'CTX_SIZE / IMAGE_MIN_TOKENS / IMAGE_MAX_TOKENS 必须大于 0'
    }
    if ([int]$ImageMinTokens -gt [int]$ImageMaxTokens) {
        throw 'IMAGE_MIN_TOKENS 不能大于 IMAGE_MAX_TOKENS'
    }
    if ($MmprojOffload -ne 'on' -and $MmprojOffload -ne 'off') {
        throw 'MMPROJ_OFFLOAD 仅支持 on 或 off'
    }
}

function Start-Server {
    if (-not (Test-Path $BinPath)) {
        throw "llama-server.exe 不存在: $BinPath"
    }
    if (-not (Test-Path $ModelPath) -or -not (Test-Path $MmprojPath)) {
        throw "模型文件不完整。`nMODEL_PATH=$ModelPath`nMMPROJ_PATH=$MmprojPath"
    }

    Ensure-Dir $WebuiDir
    Validate-Limits
    $profile = Resolve-RuntimeProfile
    Stop-Server

    $args = @(
        '-m', $ModelPath,
        '-mm', $MmprojPath,
        '--n-gpu-layers', 'all',
        '--flash-attn', 'on',
        '--fit', 'on',
        '--fit-target', '256',
        '--temp', '1.0',
        '--top-p', '0.95',
        '--top-k', '20',
        '--min-p', '0.1',
        '--presence-penalty', '1.5',
        '--repeat-penalty', '1.05',
        '-n', $profile.MaxTokens,
        '--reasoning-budget', $profile.ReasoningBudget,
        '-c', $CtxSize,
        '--image-min-tokens', $ImageMinTokens,
        '--image-max-tokens', $ImageMaxTokens,
        '--host', $HostAddr,
        '--port', $PortNum,
        '--webui'
    )

    if ($MmprojOffload -eq 'off') {
        $args += '--no-mmproj-offload'
    } else {
        $args += '--mmproj-offload'
    }

    $logPath = Join-Path $WebuiDir ("llama_server_9b_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $proc = Start-Process -FilePath $BinPath -ArgumentList $args -WindowStyle Hidden -PassThru
    Set-Content -Path $PidFile -Value $proc.Id -Encoding ascii
    Set-Content -Path $CurrentLogFile -Value $logPath -Encoding utf8

    if (-not (Wait-Ready)) {
        throw '服务启动失败，后端在 60 秒内未就绪。'
    }

    Write-Host "已切换到 9b ($ThinkMode)"
    Write-Host "地址: http://$HostAddr`:$PortNum"
    Write-Host "视觉限制: image tokens $ImageMinTokens-$ImageMaxTokens, mmproj offload=$MmprojOffload, ctx=$CtxSize"
    Show-Status
}

switch ($Command) {
    'status' { Show-Status; break }
    'stop' { Stop-Server; Write-Host '服务已停止'; break }
    '9b' { Start-Server; break }
    default {
        Write-Host '用法:'
        Write-Host '  .\\switch_qwen35_webui.ps1 status'
        Write-Host '  .\\switch_qwen35_webui.ps1 stop'
        Write-Host '  .\\switch_qwen35_webui.ps1 9b [think-on|think-off]'
        exit 1
    }
}
