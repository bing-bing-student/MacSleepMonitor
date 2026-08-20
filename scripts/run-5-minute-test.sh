#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BINARY="${PROJECT_DIR}/.build/release/mac-sleep-monitor"
OUTPUT_ROOT="${1:-${HOME}/MacSleepMonitorData/manual-tests}"
RUN_ID="$(date '+%Y-%m-%d_%H-%M-%S')"
RUN_DIR="${OUTPUT_ROOT}/${RUN_ID}"

if [[ ! -x "${BINARY}" ]]; then
  echo "未找到 Release 可执行文件，请先运行："
  echo "  swift build -c release"
  exit 1
fi

mkdir -p "${RUN_DIR}"

echo "开始采集 5 分钟，输出目录：${RUN_DIR}"
sudo "${BINARY}" collect \
  --duration 300 \
  --interval 1 \
  --top 10 \
  --database "${RUN_DIR}/monitor.sqlite" \
  --csv-directory "${RUN_DIR}/csv"

echo "生成 HTML 报告..."
sudo "${BINARY}" report \
  --database "${RUN_DIR}/monitor.sqlite" \
  --output "${RUN_DIR}/report.html" \
  --bucket 5

sudo chown -R "$(id -un):$(id -gn)" "${RUN_DIR}"
chmod -R u+rwX,go+rX "${RUN_DIR}"

echo "测试完成：${RUN_DIR}/report.html"
open "${RUN_DIR}/report.html"
