#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON_BIN="$ROOT_DIR/.venv-qwen35/bin/python"
GATEWAY_RUN="$ROOT_DIR/run_8080_toolhub_gateway.py"
RUNTIME_DIR="$ROOT_DIR/.tmp/toolhub_gateway"
PID_FILE="$RUNTIME_DIR/gateway.pid"
LOG_FILE="$RUNTIME_DIR/gateway.log"
MODEL_SWITCH="$ROOT_DIR/switch_qwen35_webui.sh"

GATEWAY_HOST="${GATEWAY_HOST:-127.0.0.1}"
GATEWAY_PORT="${GATEWAY_PORT:-8080}"
BACKEND_HOST="${BACKEND_HOST:-127.0.0.1}"
BACKEND_PORT="${BACKEND_PORT:-8081}"
THINK_MODE="${THINK_MODE:-think-on}"

mkdir -p "$RUNTIME_DIR"

is_gateway_running() {
  if [[ ! -f "$PID_FILE" ]]; then
    return 1
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  [[ -n "$pid" ]] || return 1
  ps -p "$pid" >/dev/null 2>&1
}

gateway_ready() {
  curl --noproxy '*' -sS -m 2 "http://$GATEWAY_HOST:$GATEWAY_PORT/gateway/health" >/dev/null 2>&1
}

start_backend() {
  local model_key="${MODEL_KEY:-9b}"
  if [[ "$model_key" != "9b" ]]; then
    echo "当前交付包仅支持 MODEL_KEY=9b，收到: $model_key"
    exit 1
  fi
  (
    cd "$ROOT_DIR"
    HOST="$BACKEND_HOST" PORT="$BACKEND_PORT" "$MODEL_SWITCH" "9b" "$THINK_MODE"
  )
}

start_gateway() {
  if is_gateway_running; then
    echo "网关状态: 已运行"
    echo "PID: $(cat "$PID_FILE")"
    return
  fi
  setsid "$PYTHON_BIN" "$GATEWAY_RUN" \
    --host "$GATEWAY_HOST" \
    --port "$GATEWAY_PORT" \
    --backend-base "http://$BACKEND_HOST:$BACKEND_PORT" \
    --model-server "http://$BACKEND_HOST:$BACKEND_PORT/v1" \
    >"$LOG_FILE" 2>&1 < /dev/null &
  echo "$!" >"$PID_FILE"

  local retry=0
  while (( retry < 60 )); do
    if ! is_gateway_running; then
      break
    fi
    if gateway_ready; then
      break
    fi
    retry=$((retry + 1))
    sleep 1
  done
  if ! is_gateway_running || ! gateway_ready; then
    echo "网关启动失败，日志如下:"
    tail -n 120 "$LOG_FILE" || true
    exit 1
  fi
}

stop_gateway() {
  if ! is_gateway_running; then
    rm -f "$PID_FILE"
    echo "网关状态: 未运行"
    return
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  kill "$pid" >/dev/null 2>&1 || true
  sleep 1
  if ps -p "$pid" >/dev/null 2>&1; then
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
  rm -f "$PID_FILE"
  echo "网关状态: 已停止"
}

show_status() {
  echo "=== 网关 ==="
  if is_gateway_running; then
    local web_state="初始化中"
    if gateway_ready; then
      web_state="可访问"
    fi
    echo "状态: 运行中"
    echo "PID: $(cat "$PID_FILE")"
    echo "地址: http://$GATEWAY_HOST:$GATEWAY_PORT"
    echo "健康: $web_state"
    echo "日志: $LOG_FILE"
  else
    echo "状态: 未运行"
  fi
  echo
  echo "=== 模型后端 ==="
  (
    cd "$ROOT_DIR"
    HOST="$BACKEND_HOST" PORT="$BACKEND_PORT" "$MODEL_SWITCH" status
  )
}

show_logs() {
  echo "=== 网关日志 ==="
  tail -n 120 "$LOG_FILE" || true
}

start_stack() {
  start_backend
  start_gateway
  echo "栈已启动"
  echo "前端入口: http://$GATEWAY_HOST:$GATEWAY_PORT"
  echo "模型后端: http://$BACKEND_HOST:$BACKEND_PORT"
}

stop_stack() {
  stop_gateway
  (
    cd "$ROOT_DIR"
    HOST="$BACKEND_HOST" PORT="$BACKEND_PORT" "$MODEL_SWITCH" stop
  )
}

case "${1:-status}" in
  start)
    start_stack
    ;;
  stop)
    stop_stack
    ;;
  restart)
    stop_stack
    start_stack
    ;;
  status)
    show_status
    ;;
  logs)
    show_logs
    ;;
  *)
    cat <<'EOF'
用法:
  ./start_8080_toolhub_stack.sh {start|stop|restart|status|logs}

可选环境变量:
  GATEWAY_HOST=127.0.0.1
  GATEWAY_PORT=8080
  BACKEND_HOST=127.0.0.1
  BACKEND_PORT=8081
  THINK_MODE=think-on
EOF
    exit 1
    ;;
esac
