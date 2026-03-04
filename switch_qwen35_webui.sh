#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_PATH="$ROOT_DIR/.tmp/llama_win_cuda/llama-server.exe"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8080}"
CTX_SIZE="${CTX_SIZE:-16384}"
IMAGE_MIN_TOKENS="${IMAGE_MIN_TOKENS:-256}"
IMAGE_MAX_TOKENS="${IMAGE_MAX_TOKENS:-1024}"
MMPROJ_OFFLOAD="${MMPROJ_OFFLOAD:-off}"
MODEL_PATH="${MODEL_PATH:-$ROOT_DIR/.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF/Qwen3.5-9B-Q4_K_M.gguf}"
MMPROJ_PATH="${MMPROJ_PATH:-$ROOT_DIR/.tmp/models/crossrepo/lmstudio-community__Qwen3.5-9B-GGUF/mmproj-Qwen3.5-9B-BF16.gguf}"
WEBUI_DIR="$ROOT_DIR/.tmp/webui"
PID_FILE="$WEBUI_DIR/llama_server.pid"
LOG_FILE="$WEBUI_DIR/current.log"
LAUNCHER_PS1="$WEBUI_DIR/start_llama_server.ps1"

mkdir -p "$WEBUI_DIR"

print_usage() {
  cat <<'EOF'
用法:
  ./switch_qwen35_webui.sh status
  ./switch_qwen35_webui.sh stop
  ./switch_qwen35_webui.sh 9b [think-on|think-off]

可选环境变量:
  HOST=127.0.0.1           # 监听地址
  PORT=8080                # 监听端口
  CTX_SIZE=16384            # 上下文长度
  IMAGE_MIN_TOKENS=256      # 单图最小视觉 token
  IMAGE_MAX_TOKENS=1024     # 单图最大视觉 token
  MMPROJ_OFFLOAD=off|on     # 多模态投影是否上 GPU，off 更稳，on 更快
  MODEL_PATH=...            # 9B 主模型路径
  MMPROJ_PATH=...           # 9B 多模态投影模型路径
EOF
}

resolve_model_paths() {
  local model_key="$1"
  if [[ "$model_key" != "9b" ]]; then
    echo "仅支持 9b，收到: $model_key"
    exit 1
  fi
}

stop_server() {
  cmd.exe /c "taskkill /IM llama-server.exe /F >nul 2>&1" >/dev/null 2>&1 || true
  sleep 1
  rm -f "$PID_FILE"
}

health_ok() {
  curl --noproxy '*' -sS -m 2 "http://$HOST:$PORT/health" >/dev/null 2>&1
}

models_ready() {
  local model_json
  model_json="$(curl --noproxy '*' -sS -m 3 "http://$HOST:$PORT/v1/models" || true)"
  [[ "$model_json" == *'"id":"'*
  ]]
}

wait_for_ready() {
  local retry=0
  while (( retry < 60 )); do
    if health_ok && models_ready; then
      return 0
    fi
    retry=$((retry + 1))
    sleep 1
  done
  return 1
}

show_status() {
  if health_ok; then
    local model_json
    model_json="$(curl --noproxy '*' -sS -m 3 "http://$HOST:$PORT/v1/models" || true)"
    local model_name
    model_name="$(printf '%s' "$model_json" | rg -o '"id":"[^"]+"' | head -n1 | sed 's/"id":"//;s/"$//' || true)"
    [[ -n "$model_name" ]] || model_name="loading"
    echo "状态: 运行中"
    echo "地址: http://$HOST:$PORT"
    echo "模型: ${model_name:-unknown}"
    if [[ -f "$LOG_FILE" ]]; then
      echo "日志: $(cat "$LOG_FILE")"
    fi
  else
    echo "状态: 未运行"
  fi
}

resolve_runtime_profile() {
  local think_mode="$1"
  case "$think_mode" in
    "think-on")
      REASONING_BUDGET="-1"
      MAX_TOKENS="-1"
      ;;
    "think-off")
      REASONING_BUDGET="0"
      MAX_TOKENS="2048"
      ;;
    *)
      echo "不支持的思考模式: $think_mode"
      exit 1
      ;;
  esac
}

validate_runtime_limits() {
  if ! [[ "$CTX_SIZE" =~ ^[0-9]+$ && "$IMAGE_MIN_TOKENS" =~ ^[0-9]+$ && "$IMAGE_MAX_TOKENS" =~ ^[0-9]+$ ]]; then
    echo "CTX_SIZE / IMAGE_MIN_TOKENS / IMAGE_MAX_TOKENS 必须是正整数"
    exit 1
  fi
  if (( IMAGE_MIN_TOKENS <= 0 || IMAGE_MAX_TOKENS <= 0 || CTX_SIZE <= 0 )); then
    echo "CTX_SIZE / IMAGE_MIN_TOKENS / IMAGE_MAX_TOKENS 必须大于 0"
    exit 1
  fi
  if (( IMAGE_MIN_TOKENS > IMAGE_MAX_TOKENS )); then
    echo "IMAGE_MIN_TOKENS 不能大于 IMAGE_MAX_TOKENS"
    exit 1
  fi
  case "$MMPROJ_OFFLOAD" in
    "on"|"off") ;;
    *)
      echo "MMPROJ_OFFLOAD 仅支持 on 或 off"
      exit 1
      ;;
  esac
}

start_server() {
  local model_key="$1"
  local think_mode="${2:-think-on}"
  resolve_model_paths "$model_key"
  resolve_runtime_profile "$think_mode"
  validate_runtime_limits
  if [[ ! -f "$MODEL_PATH" || ! -f "$MMPROJ_PATH" ]]; then
    echo "模型文件不完整:"
    echo "MODEL_PATH=$MODEL_PATH"
    echo "MMPROJ_PATH=$MMPROJ_PATH"
    exit 1
  fi

  stop_server

  local model_win mmproj_win bin_win log_path ps1_win pid_out
  model_win="$(wslpath -w "$MODEL_PATH")"
  mmproj_win="$(wslpath -w "$MMPROJ_PATH")"
  bin_win="$(wslpath -w "$BIN_PATH")"
  log_path="$WEBUI_DIR/llama_server_${model_key}_$(date +%Y%m%d_%H%M%S).log"
  cat >"$LAUNCHER_PS1" <<'EOF'
param(
  [string]$BinPath,
  [string]$ModelPath,
  [string]$MMProjPath,
  [string]$HostAddr,
  [string]$PortNum,
  [string]$ReasoningBudget,
  [string]$MaxTokens,
  [string]$CtxSize,
  [string]$ImageMinTokens,
  [string]$ImageMaxTokens,
  [string]$MMProjOffload
)

$argsList = @(
  '-m', $ModelPath,
  '-mm', $MMProjPath,
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
  '-n', $MaxTokens,
  '--reasoning-budget', $ReasoningBudget,
  '-c', $CtxSize,
  '--image-min-tokens', $ImageMinTokens,
  '--image-max-tokens', $ImageMaxTokens,
  '--host', $HostAddr,
  '--port', $PortNum,
  '--webui'
)

if ($MMProjOffload -eq 'off') {
  $argsList += '--no-mmproj-offload'
} else {
  $argsList += '--mmproj-offload'
}

$p = Start-Process -FilePath $BinPath -ArgumentList $argsList -WindowStyle Hidden -PassThru
Write-Output $p.Id
EOF
  ps1_win="$(wslpath -w "$LAUNCHER_PS1")"
  pid_out="$(
    powershell.exe -NoProfile -File "$ps1_win" \
      -BinPath "$bin_win" \
      -ModelPath "$model_win" \
      -MMProjPath "$mmproj_win" \
      -HostAddr "$HOST" \
      -PortNum "$PORT" \
      -ReasoningBudget "$REASONING_BUDGET" \
      -MaxTokens "$MAX_TOKENS" \
      -CtxSize "$CTX_SIZE" \
      -ImageMinTokens "$IMAGE_MIN_TOKENS" \
      -ImageMaxTokens "$IMAGE_MAX_TOKENS" \
      -MMProjOffload "$MMPROJ_OFFLOAD" \
    | tr -d '\r' | tail -n1
  )"

  echo "${pid_out:-0}" >"$PID_FILE"
  echo "$log_path" >"$LOG_FILE"

  if ! wait_for_ready; then
    echo "服务启动失败，最近日志:"
    tail -n 80 "$log_path" || true
    exit 1
  fi

  echo "已切换到 $model_key ($think_mode)"
  echo "地址: http://$HOST:$PORT"
  echo "视觉限制: image tokens $IMAGE_MIN_TOKENS-$IMAGE_MAX_TOKENS, mmproj offload=$MMPROJ_OFFLOAD, ctx=$CTX_SIZE"
  show_status
}

main() {
  local cmd="${1:-}"
  local think_mode="${2:-think-on}"
  case "$cmd" in
    "status")
      show_status
      ;;
    "stop")
      stop_server
      echo "服务已停止"
      ;;
    "9b")
      start_server "$cmd" "$think_mode"
      ;;
    *)
      print_usage
      exit 1
      ;;
  esac
}

main "${1:-}" "${2:-}"
