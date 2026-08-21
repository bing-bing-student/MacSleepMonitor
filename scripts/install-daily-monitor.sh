#!/bin/bash

set -euo pipefail

LABEL="com.local.macsleepmonitor.daily"
INSTALL_DIR="/usr/local/libexec"
BINARY_PATH="${INSTALL_DIR}/mac-sleep-monitor"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  cat <<'EOF'
用法：
  sudo ./scripts/install-daily-monitor.sh [开始时间] [结束时间] [数据目录] [--process 进程名称]...

示例：
  sudo ./scripts/install-daily-monitor.sh 05:00 08:00
  sudo ./scripts/install-daily-monitor.sh 3:30 7:50
  sudo ./scripts/install-daily-monitor.sh 23:30 02:00 "$HOME/MacSleepMonitorData"
  sudo ./scripts/install-daily-monitor.sh 05:00 08:00 "$HOME/MacSleepMonitorData" --process node --process "Google Chrome"

定时任务固定每 5 秒采样一次；五分钟测试脚本仍每 1 秒采样一次。
结束时间早于开始时间时，按次日结束处理。
指定后只采集这些进程；最多 10 个名称。不指定时保持原有 Top 10 并集采集方式。
EOF
  exit 0
fi

START_TIME="${1:-05:00}"
if [[ "$#" -gt 0 ]]; then shift; fi
END_TIME="08:00"
if [[ "$#" -gt 0 ]]; then
  END_TIME="$1"
  shift
else
  END_TIME="08:00"
fi

OUTPUT_ROOT_ARGUMENT=""
if [[ "$#" -gt 0 && "$1" != "--process" ]]; then
  OUTPUT_ROOT_ARGUMENT="$1"
  shift
fi

PROCESS_NAMES=()
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" != "--process" ]]; then
    echo "未知参数：$1"
    exit 1
  fi
  if [[ "$#" -lt 2 || -z "$2" ]]; then
    echo "--process 缺少进程名称。"
    exit 1
  fi
  if [[ "${#PROCESS_NAMES[@]}" -ge 10 ]]; then
    echo "最多只能指定 10 个进程名称。"
    exit 1
  fi
  PROCESS_NAMES+=("$2")
  shift 2
done

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。"
  exit 1
fi

REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory | awk '{print $2}')"
REAL_GROUP="$(id -gn "${REAL_USER}")"
OUTPUT_ROOT="${OUTPUT_ROOT_ARGUMENT:-${REAL_HOME}/MacSleepMonitorData}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_BINARY="${PROJECT_DIR}/.build/release/mac-sleep-monitor"

xml_escape() {
  local value="$1"
  value="${value//&/&amp;}"
  value="${value//</&lt;}"
  value="${value//>/&gt;}"
  printf '%s' "${value}"
}

TIME_PATTERN='^([01]?[0-9]|2[0-3]):[0-5][0-9]$'

if [[ ! "${START_TIME}" =~ ${TIME_PATTERN} ]]; then
  echo "开始时间无效：${START_TIME}，请使用 HH:MM，例如 03:30"
  exit 1
fi

if [[ ! "${END_TIME}" =~ ${TIME_PATTERN} ]]; then
  echo "结束时间无效：${END_TIME}，请使用 HH:MM，例如 07:50"
  exit 1
fi

IFS=':' read -r START_HOUR START_MINUTE <<< "${START_TIME}"
IFS=':' read -r END_HOUR END_MINUTE <<< "${END_TIME}"
START_HOUR="$((10#${START_HOUR}))"
START_MINUTE="$((10#${START_MINUTE}))"
END_HOUR="$((10#${END_HOUR}))"
END_MINUTE="$((10#${END_MINUTE}))"
START_TIME_NORMALIZED="$(printf '%02d:%02d' "${START_HOUR}" "${START_MINUTE}")"
END_TIME_NORMALIZED="$(printf '%02d:%02d' "${END_HOUR}" "${END_MINUTE}")"

if [[ "${START_TIME_NORMALIZED}" == "${END_TIME_NORMALIZED}" ]]; then
  echo "开始时间和结束时间不能相同。"
  exit 1
fi

if [[ ! -x "${SOURCE_BINARY}" ]]; then
  echo "未找到 Release 可执行文件，请先运行："
  echo "  swift build -c release"
  exit 1
fi

launchctl bootout system "${PLIST_PATH}" >/dev/null 2>&1 || true
mkdir -p "${INSTALL_DIR}" "${OUTPUT_ROOT}"
install -o root -g wheel -m 755 "${SOURCE_BINARY}" "${BINARY_PATH}"
OUTPUT_ROOT_XML="$(xml_escape "${OUTPUT_ROOT}")"
PROCESS_ARGUMENTS_XML=""
for process_name in "${PROCESS_NAMES[@]}"; do
  process_name_xml="$(xml_escape "${process_name}")"
  PROCESS_ARGUMENTS_XML+="    <string>--process</string>"$'\n'
  PROCESS_ARGUMENTS_XML+="    <string>${process_name_xml}</string>"$'\n'
done

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${BINARY_PATH}</string>
    <string>scheduled-run</string>
    <string>--start</string>
    <string>${START_TIME_NORMALIZED}</string>
    <string>--end</string>
    <string>${END_TIME_NORMALIZED}</string>
    <string>--output-root</string>
    <string>${OUTPUT_ROOT_XML}</string>
    <string>--interval</string>
    <string>5</string>
    <string>--top</string>
    <string>10</string>
    <string>--bucket</string>
    <string>30</string>
${PROCESS_ARGUMENTS_XML}
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>${START_HOUR}</integer>
    <key>Minute</key>
    <integer>${START_MINUTE}</integer>
  </dict>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>StandardOutPath</key>
  <string>${OUTPUT_ROOT_XML}/launchd.stdout.log</string>
  <key>StandardErrorPath</key>
  <string>${OUTPUT_ROOT_XML}/launchd.stderr.log</string>
</dict>
</plist>
EOF

chown root:wheel "${PLIST_PATH}"
chmod 644 "${PLIST_PATH}"
chown "${REAL_USER}:${REAL_GROUP}" "${OUTPUT_ROOT}"
chmod 755 "${OUTPUT_ROOT}"

plutil -lint "${PLIST_PATH}"
launchctl bootstrap system "${PLIST_PATH}"

echo "定时监控已安装。"
echo "采集时间：每天 ${START_TIME_NORMALIZED} 到 ${END_TIME_NORMALIZED}"
echo "采样间隔：5 秒"
if [[ "${#PROCESS_NAMES[@]}" -gt 0 ]]; then
  echo "仅采集指定进程：${PROCESS_NAMES[*]}"
fi
echo "报告目录：${OUTPUT_ROOT}/YYYY-MM-DD/report.html"
echo "任务状态：sudo launchctl print system/${LABEL}"
