#!/bin/bash

set -euo pipefail

LABEL="com.local.macsleepmonitor.daily"
INSTALL_DIR="/usr/local/libexec"
BINARY_PATH="${INSTALL_DIR}/mac-sleep-monitor"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"

START_HOUR="${1:-5}"
START_MINUTE="${2:-0}"
END_TIME="${3:-08:00}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "请使用 sudo 运行此脚本。"
  exit 1
fi

REAL_USER="${SUDO_USER:-root}"
REAL_HOME="$(dscl . -read "/Users/${REAL_USER}" NFSHomeDirectory | awk '{print $2}')"
REAL_GROUP="$(id -gn "${REAL_USER}")"
OUTPUT_ROOT="${4:-${REAL_HOME}/MacSleepMonitorData}"
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

if [[ ! "${START_HOUR}" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; then
  echo "开始小时无效：${START_HOUR}"
  exit 1
fi

if [[ ! "${START_MINUTE}" =~ ^([0-9]|[1-5][0-9])$ ]]; then
  echo "开始分钟无效：${START_MINUTE}"
  exit 1
fi

if [[ ! "${END_TIME}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
  echo "结束时间无效：${END_TIME}"
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
    <string>--end</string>
    <string>${END_TIME}</string>
    <string>--output-root</string>
    <string>${OUTPUT_ROOT_XML}</string>
    <string>--interval</string>
    <string>2</string>
    <string>--top</string>
    <string>10</string>
    <string>--bucket</string>
    <string>30</string>
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
echo "采集时间：每天 $(printf '%02d:%02d' "${START_HOUR}" "${START_MINUTE}") 到 ${END_TIME}"
echo "报告目录：${OUTPUT_ROOT}/YYYY-MM-DD/report.html"
echo "任务状态：sudo launchctl print system/${LABEL}"
