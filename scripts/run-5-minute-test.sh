#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARY="${PROJECT_DIR}/.build/release/mac-sleep-monitor"
OUTPUT_ROOT="${HOME}/MacSleepMonitorData/manual-tests"
PROCESS_ARGS=()
PROCESS_COUNT=0

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --process)
      if [[ "$#" -lt 2 || -z "$2" ]]; then
        echo "--process 缺少进程名称。"
        exit 1
      fi
      if [[ "${PROCESS_COUNT}" -ge 10 ]]; then
        echo "最多只能指定 10 个进程名称。"
        exit 1
      fi
      PROCESS_ARGS+=(--process "$2")
      PROCESS_COUNT="$((PROCESS_COUNT + 1))"
      shift 2
      ;;
    --output-root)
      if [[ "$#" -lt 2 || -z "$2" ]]; then
        echo "--output-root 缺少目录。"
        exit 1
      fi
      OUTPUT_ROOT="$2"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
用法：
  ./scripts/run-5-minute-test.sh [--process 进程名称]... [--output-root 数据目录]

示例：
  ./scripts/run-5-minute-test.sh
  ./scripts/run-5-minute-test.sh --process node --process "Google Chrome"

最多指定 10 个进程名称；不指定时保持原有 Top 10 并集采集方式。
EOF
      exit 0
      ;;
    *)
      echo "未知参数：$1"
      exit 1
      ;;
  esac
done

RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"

echo "检查并更新 Release 可执行文件..."
if ! swift build -c release --package-path "${PROJECT_DIR}"; then
  echo "普通构建受 SwiftPM 沙箱限制，使用 --disable-sandbox 重试..."
  if ! swift build -c release --disable-sandbox --package-path "${PROJECT_DIR}"; then
    echo "Release 构建失败，未开始采集。"
    exit 1
  fi
fi

mkdir -p "${RUN_DIR}"

echo "开始采集 5 分钟，输出目录：${RUN_DIR}"
sudo "${BINARY}" collect \
  --duration 300 \
  --interval 1 \
  --top 10 \
  --database "${RUN_DIR}/monitor.sqlite" \
  --csv-directory "${RUN_DIR}/csv" \
  "${PROCESS_ARGS[@]}"

echo "生成 HTML 报告..."
sudo "${BINARY}" report \
  --database "${RUN_DIR}/monitor.sqlite" \
  --output "${RUN_DIR}/report.html" \
  --bucket 5

sudo chown -R "$(id -un):$(id -gn)" "${RUN_DIR}"
chmod -R u+rwX,go+rX "${RUN_DIR}"

echo "测试完成：${RUN_DIR}/report.html"
open "${RUN_DIR}/report.html"
