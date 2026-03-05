#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PS1_PATH="$ROOT_DIR/switch_qwen35_webui.ps1"

print_usage() {
  cat <<'USAGE'
用法:
  ./switch_qwen35_webui.sh status
  ./switch_qwen35_webui.sh stop
  ./switch_qwen35_webui.sh 9b [think-on|think-off]

说明:
  WSL 入口会直接复用 Windows 主脚本的 GPU 强校验逻辑。
  若未成功加载到 GPU，脚本会直接失败，不会回退 CPU。
USAGE
}

to_win_path_if_needed() {
  local raw="$1"
  if [[ -z "$raw" ]]; then
    printf ''
    return
  fi
  if [[ "$raw" == /* ]]; then
    wslpath -w "$raw"
    return
  fi
  printf '%s' "$raw"
}

require_windows_power_shell() {
  if ! command -v powershell.exe >/dev/null 2>&1; then
    echo "未找到 powershell.exe，WSL 模式无法调用 Windows 后端脚本。"
    exit 1
  fi
  if [[ ! -f "$PS1_PATH" ]]; then
    echo "缺少后端脚本: $PS1_PATH"
    exit 1
  fi
}

build_env_overrides() {
  local -n out_ref=$1
  out_ref=()
  for key in HOST PORT CTX_SIZE IMAGE_MIN_TOKENS IMAGE_MAX_TOKENS MMPROJ_OFFLOAD GPU_MEMORY_DELTA_MIN_MIB; do
    if [[ -n "${!key-}" ]]; then
      out_ref+=("$key=${!key}")
    fi
  done

  if [[ -n "${BIN_PATH-}" ]]; then
    out_ref+=("BIN_PATH=$(to_win_path_if_needed "$BIN_PATH")")
  fi
  if [[ -n "${MODEL_PATH-}" ]]; then
    out_ref+=("MODEL_PATH=$(to_win_path_if_needed "$MODEL_PATH")")
  fi
  if [[ -n "${MMPROJ_PATH-}" ]]; then
    out_ref+=("MMPROJ_PATH=$(to_win_path_if_needed "$MMPROJ_PATH")")
  fi
}

main() {
  local command="${1:-status}"
  local think_mode="${2:-think-on}"

  case "$command" in
    status|stop) ;;
    9b)
      case "$think_mode" in
        think-on|think-off) ;;
        *)
          echo "不支持的思考模式: $think_mode"
          exit 1
          ;;
      esac
      ;;
    *)
      print_usage
      exit 1
      ;;
  esac

  require_windows_power_shell

  local ps1_win
  ps1_win="$(wslpath -w "$PS1_PATH")"

  local env_overrides=()
  build_env_overrides env_overrides

  if [[ "$command" == "9b" ]]; then
    env "${env_overrides[@]}" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps1_win" "$command" "$think_mode"
    return
  fi

  env "${env_overrides[@]}" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps1_win" "$command"
}

main "${1:-status}" "${2:-think-on}"
