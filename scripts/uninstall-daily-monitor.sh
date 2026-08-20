#!/bin/bash

set -euo pipefail

LABEL="com.local.macsleepmonitor.daily"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
BINARY_PATH="/usr/local/libexec/mac-sleep-monitor"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。"
  exit 1
fi

launchctl bootout system "${PLIST_PATH}" >/dev/null 2>&1 || true
rm -f "${PLIST_PATH}" "${BINARY_PATH}"

echo "定时监控已卸载。历史数据没有删除。"
