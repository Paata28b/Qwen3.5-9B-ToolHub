param()

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = (Resolve-Path $ScriptDir).Path
$VenvDir = Join-Path $RootDir '.venv-qwen35'
$VenvPython = Join-Path $VenvDir 'Scripts\python.exe'
$LlamaDir = Join-Path $RootDir '.tmp\llama_win_cuda'
$ModelDir = Join-Path $RootDir '.tmp\models\crossrepo\lmstudio-community__Qwen3.5-9B-GGUF'
$GgufPath = Join-Path $ModelDir 'Qwen3.5-9B-Q4_K_M.gguf'
$MmprojPath = Join-Path $ModelDir 'mmproj-Qwen3.5-9B-BF16.gguf'

$DefaultGgufUrl = 'https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf'
$DefaultMmprojUrl = 'https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/mmproj-Qwen3.5-9B-BF16.gguf'
$AssetPattern = 'win-cuda-cu12\.4.*x64\.zip$'

function Write-Step {
    param([string]$Message)
    Write-Host "[install] $Message"
}

function Get-PythonExe {
    if ($env:PYTHON_BIN -and (Test-Path $env:PYTHON_BIN)) {
        return $env:PYTHON_BIN
    }
    $pyCmd = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyCmd) {
        return 'py -3'
    }
    $pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
    if ($pythonCmd) {
        return 'python'
    }
    throw '未找到可用 Python，请安装 Python 3.10+ 并加入 PATH。'
}

function Invoke-Python {
    param(
        [string]$PythonSpec,
        [string[]]$Args
    )
    if ($PythonSpec -eq 'py -3') {
        & py -3 @Args
        return
    }
    & $PythonSpec @Args
}

function Ensure-Dir {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
}

function Download-File {
    param(
        [string]$Url,
        [string]$OutFile
    )
    Write-Step "下载: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
}

function Verify-Sha256 {
    param(
        [string]$Path,
        [string]$Expected
    )
    if ([string]::IsNullOrWhiteSpace($Expected)) {
        return
    }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    $exp = $Expected.ToLowerInvariant()
    if ($actual -ne $exp) {
        throw "SHA256 校验失败: $Path"
    }
}

function Resolve-LlamaCudaUrl {
    if ($env:LLAMA_WIN_CUDA_URL) {
        return $env:LLAMA_WIN_CUDA_URL
    }
    $api = 'https://api.github.com/repos/ggml-org/llama.cpp/releases/latest'
    $release = Invoke-RestMethod -Uri $api -Method Get
    foreach ($asset in $release.assets) {
        if ($asset.name -match $AssetPattern) {
            return $asset.browser_download_url
        }
    }
    throw '自动解析 llama.cpp CUDA 下载地址失败，请设置 LLAMA_WIN_CUDA_URL。'
}

function Ensure-PythonEnv {
    $python = Get-PythonExe
    if (-not (Test-Path $VenvDir)) {
        Write-Step "创建虚拟环境: $VenvDir"
        Invoke-Python -PythonSpec $python -Args @('-m', 'venv', $VenvDir)
    }
    if (-not (Test-Path $VenvPython)) {
        throw "虚拟环境 Python 不存在: $VenvPython"
    }
    Write-Step '安装 Python 依赖'
    & $VenvPython -m pip install --upgrade pip wheel
    & $VenvPython -m pip install -r (Join-Path $RootDir 'requirements.txt')
}

function Ensure-LlamaRuntime {
    Ensure-Dir $LlamaDir
    $llamaExe = Join-Path $LlamaDir 'llama-server.exe'
    if (Test-Path $llamaExe) {
        Write-Step '检测到现有 llama-server.exe，跳过下载'
        return
    }

    $zipPath = Join-Path $LlamaDir 'llama-win-cuda.zip'
    $url = Resolve-LlamaCudaUrl
    Download-File -Url $url -OutFile $zipPath

    Write-Step '解压 llama.cpp CUDA 运行时'
    Expand-Archive -Path $zipPath -DestinationPath $LlamaDir -Force

    if (-not (Test-Path $llamaExe)) {
        $found = Get-ChildItem -Path $LlamaDir -Filter 'llama-server.exe' -Recurse -File | Select-Object -First 1
        if (-not $found) {
            throw 'llama-server.exe 下载或解压失败。'
        }
        $srcDir = Split-Path -Parent $found.FullName
        Copy-Item -Path (Join-Path $srcDir '*') -Destination $LlamaDir -Recurse -Force
    }

    if (-not (Test-Path $llamaExe)) {
        throw 'llama-server.exe 下载或解压失败。'
    }
}

function Ensure-ModelFiles {
    Ensure-Dir $ModelDir

    $ggufUrl = if ($env:MODEL_GGUF_URL) { $env:MODEL_GGUF_URL } else { $DefaultGgufUrl }
    $mmprojUrl = if ($env:MODEL_MMPROJ_URL) { $env:MODEL_MMPROJ_URL } else { $DefaultMmprojUrl }

    if (-not (Test-Path $GgufPath)) {
        Download-File -Url $ggufUrl -OutFile $GgufPath
    } else {
        Write-Step '检测到现有 9B 主模型，跳过下载'
    }

    if (-not (Test-Path $MmprojPath)) {
        Download-File -Url $mmprojUrl -OutFile $MmprojPath
    } else {
        Write-Step '检测到现有 mmproj，跳过下载'
    }

    Verify-Sha256 -Path $GgufPath -Expected $env:MODEL_GGUF_SHA256
    Verify-Sha256 -Path $MmprojPath -Expected $env:MODEL_MMPROJ_SHA256
}

function Main {
    Ensure-PythonEnv
    Ensure-LlamaRuntime
    Ensure-ModelFiles
    Write-Step '安装完成'
    Write-Step '启动命令: .\\start_8080_toolhub_stack.ps1 start'
    Write-Step '停止命令: .\\start_8080_toolhub_stack.ps1 stop'
}

Main
