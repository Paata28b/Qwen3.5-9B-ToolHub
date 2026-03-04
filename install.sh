#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"
VENV_DIR="$ROOT_DIR/.venv-qwen35"
VENV_PY="$VENV_DIR/bin/python"
LLAMA_DIR="$ROOT_DIR/.tmp/llama_win_cuda"
MODEL_DIR="$ROOT_DIR/.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF"
GGUF_PATH="$MODEL_DIR/Qwen3.5-9B-Q4_K_M.gguf"
MMPROJ_PATH="$MODEL_DIR/mmproj-Qwen3.5-9B-BF16.gguf"

DEFAULT_GGUF_URL="https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf"
DEFAULT_MMPROJ_URL="https://huggingface.co/lmstudio-community/Qwen3.5-9B-GGUF/resolve/main/mmproj-Qwen3.5-9B-BF16.gguf"

log() {
  printf '[install] %s\n' "$1"
}

fail() {
  printf '[install] ERROR: %s\n' "$1" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "缺少命令: $1"
  fi
}

verify_sha256() {
  local file_path="$1"
  local expected="$2"
  if [[ -z "$expected" ]]; then
    return 0
  fi
  local actual
  actual="$(sha256sum "$file_path" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    fail "SHA256 校验失败: $file_path"
  fi
}

download_file() {
  local url="$1"
  local out_file="$2"
  log "下载: $url"
  curl --fail --location --retry 3 --retry-delay 2 --output "$out_file" "$url"
}

resolve_latest_llama_cuda_url() {
  local release_json
  release_json="$(curl --fail --location --silent https://api.github.com/repos/ggml-org/llama.cpp/releases/latest)"
  printf '%s' "$release_json" | "$PYTHON_BIN" - <<'PY'
import json
import re
import sys

data = json.loads(sys.stdin.read())
assets = data.get('assets', [])
pattern = re.compile(r'win-cuda-cu12\.4.*x64\.zip$', re.I)
for item in assets:
    name = item.get('name', '')
    url = item.get('browser_download_url', '')
    if pattern.search(name) and url:
        print(url)
        raise SystemExit(0)
raise SystemExit(1)
PY
}

extract_zip_to_dir() {
  local zip_path="$1"
  local target_dir="$2"
  "$PYTHON_BIN" - "$zip_path" "$target_dir" <<'PY'
import sys
import zipfile

zip_path = sys.argv[1]
target_dir = sys.argv[2]
with zipfile.ZipFile(zip_path, 'r') as zf:
    zf.extractall(target_dir)
PY
}

ensure_python_env() {
  require_cmd "$PYTHON_BIN"
  if [[ ! -d "$VENV_DIR" ]]; then
    log "创建虚拟环境: $VENV_DIR"
    "$PYTHON_BIN" -m venv "$VENV_DIR"
  fi
  if [[ ! -x "$VENV_PY" ]]; then
    fail "虚拟环境 Python 不存在: $VENV_PY"
  fi
  log "安装 Python 依赖"
  "$VENV_PY" -m pip install --upgrade pip wheel
  "$VENV_PY" -m pip install -r "$ROOT_DIR/requirements.txt"
}

ensure_llama_runtime() {
  mkdir -p "$LLAMA_DIR"
  if [[ -f "$LLAMA_DIR/llama-server.exe" ]]; then
    log "检测到现有 llama-server.exe，跳过下载"
    return
  fi

  local llama_url
  llama_url="${LLAMA_WIN_CUDA_URL:-}"
  if [[ -z "$llama_url" ]]; then
    log "未指定 LLAMA_WIN_CUDA_URL，尝试自动解析 llama.cpp 最新 CUDA 包"
    if ! llama_url="$(resolve_latest_llama_cuda_url)"; then
      fail "自动解析 llama.cpp 下载地址失败，请设置 LLAMA_WIN_CUDA_URL"
    fi
  fi

  local zip_path="$LLAMA_DIR/llama-win-cuda.zip"
  download_file "$llama_url" "$zip_path"
  extract_zip_to_dir "$zip_path" "$LLAMA_DIR"

  if [[ ! -f "$LLAMA_DIR/llama-server.exe" ]]; then
    local found
    found="$(find "$LLAMA_DIR" -type f -name 'llama-server.exe' | head -n1 || true)"
    if [[ -n "$found" ]]; then
      local src_dir
      src_dir="$(dirname "$found")"
      cp -f "$src_dir"/* "$LLAMA_DIR/"
    fi
  fi

  [[ -f "$LLAMA_DIR/llama-server.exe" ]] || fail "llama-server.exe 下载或解压失败"
}

ensure_model_files() {
  mkdir -p "$MODEL_DIR"

  local gguf_url mmproj_url
  gguf_url="${MODEL_GGUF_URL:-$DEFAULT_GGUF_URL}"
  mmproj_url="${MODEL_MMPROJ_URL:-$DEFAULT_MMPROJ_URL}"

  if [[ ! -f "$GGUF_PATH" ]]; then
    download_file "$gguf_url" "$GGUF_PATH"
  else
    log "检测到现有 9B 主模型，跳过下载"
  fi

  if [[ ! -f "$MMPROJ_PATH" ]]; then
    download_file "$mmproj_url" "$MMPROJ_PATH"
  else
    log "检测到现有 mmproj，跳过下载"
  fi

  verify_sha256 "$GGUF_PATH" "${MODEL_GGUF_SHA256:-}"
  verify_sha256 "$MMPROJ_PATH" "${MODEL_MMPROJ_SHA256:-}"
}

main() {
  require_cmd curl
  require_cmd sha256sum
  ensure_python_env
  ensure_llama_runtime
  ensure_model_files

  log "安装完成"
  log "启动命令: ./start_8080_toolhub_stack.sh start"
  log "停止命令: ./start_8080_toolhub_stack.sh stop"
}

main "$@"
