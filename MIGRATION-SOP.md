# MacSleepMonitor 迁移与定时运行 SOP

这份 SOP 适用于把项目从开发用 Mac 迁移到另一台 Apple Silicon Mac，并完成五分钟测试及每天 `05:00–08:00` 的自动采集。目标电脑是 M4 Pro，硬件架构与当前项目兼容。

## 迁移原则

目标 Mac 应从源码重新编译，不直接复制当前 Mac 的 `.build` 目录。这样可以适配目标电脑的 macOS、Swift 运行库和本机安全属性。

迁移包只需要包含：

```text
MacSleepMonitor/
├── Package.swift
├── README.md
├── MIGRATION-SOP.md
├── Sources/
└── scripts/
```

`.build`、历史 SQLite、CSV 和测试报告不需要迁移。

## 复制到目标 Mac

把 `MacSleepMonitor-transfer.zip` 通过 AirDrop、移动硬盘或云盘复制到目标 Mac 的“下载”目录。

使用 Finder 双击解压，然后把 `MacSleepMonitor` 文件夹移动到：

```text
个人主目录/Projects/MacSleepMonitor
```

也可以在终端解压：

```bash
$ mkdir -p ~/Projects
```

```bash
$ ditto -x -k ~/Downloads/MacSleepMonitor-transfer.zip ~/Projects
```

进入项目目录：

```bash
$ cd ~/Projects/MacSleepMonitor
```

后续命令均在这个目录中执行。

## 准备 Swift 环境

检查 Command Line Tools：

```bash
$ xcode-select -p
```

正常情况下会显示类似：

```text
/Library/Developer/CommandLineTools
```

如果提示未安装，执行：

```bash
$ xcode-select --install
```

在系统弹窗中完成安装，然后检查 Swift：

```bash
$ swift --version
```

项目要求 Apple Swift `6.0` 或更高版本。若版本较旧，请先更新 macOS 或从 App Store 安装新版 Xcode。

恢复脚本执行权限：

```bash
$ chmod +x scripts/*.sh
```

## 本机编译

执行 Release 编译：

```bash
$ swift build -c release
```

若出现 SwiftPM 沙箱权限错误，再使用：

```bash
$ swift build -c release --disable-sandbox
```

确认可执行文件正常：

```bash
$ .build/release/mac-sleep-monitor --help
```

输出中应包含三个子命令：

```text
collect
report
scheduled-run
```

## 五分钟测试

先保持 Mac 开盖并连接网络，运行：

```bash
$ ./scripts/run-5-minute-test.sh
```

脚本会：

1. 请求管理员密码。
2. 采集五分钟。
3. 生成 SQLite、CSV 和 HTML 报告。
4. 自动打开 `report.html`。

测试数据保存在：

```text
~/MacSleepMonitorData/manual-tests/YYYY-MM-DD_HH-MM-SS/
```

报告中应能切换：

- CPU
- 内存
- 磁盘读取
- 磁盘写入
- 网络接收
- 网络发送
- 打开文件

采样五分钟后应能看到多点折线。网络曲线每五秒产生一次数据；如果测试期间没有网络活动，速率可能接近零。

!!! warning 注意
第一次功能测试建议保持开盖，先确认采集、网络统计和报告都正常。确认后可以再运行一次五分钟测试并盒盖，用于观察睡眠缺口。
!!!

## 安装每天定时任务

默认时间是每天 `05:00–08:00`，执行：

```bash
$ sudo ./scripts/install-daily-monitor.sh 5 0 08:00 "$HOME/MacSleepMonitorData"
```

安装脚本会：

- 把 Release 可执行文件复制到 `/usr/local/libexec/mac-sleep-monitor`
- 创建 `/Library/LaunchDaemons/com.local.macsleepmonitor.daily.plist`
- 注册系统级 `LaunchDaemon`
- 把输出目录设置为当前登录用户可访问

安装后，项目文件夹可以移动，但建议保留，以便后续更新和卸载。

## 验证定时配置

检查 plist 内容：

```bash
$ plutil -p /Library/LaunchDaemons/com.local.macsleepmonitor.daily.plist
```

应看到：

```text
Hour = 5
Minute = 0
--end
08:00
```

检查任务是否注册：

```bash
$ sudo launchctl print system/com.local.macsleepmonitor.daily
```

在 `05:00–08:00` 之外看到 `state = not running` 属于正常状态，表示任务已经注册但当前不在运行时间。

确认目标 Mac 的系统时间和时区正确：

```bash
$ date
```

`launchd` 按目标 Mac 的本地时间运行。

## 查看每日报告

每天的数据目录为：

```text
~/MacSleepMonitorData/YYYY-MM-DD/
```

当天 `08:00` 采集结束后会出现：

```text
YYYY-MM-DD/
├── monitor.sqlite
├── report.html
└── csv/
    ├── monitor_events.csv
    └── process_samples.csv
```

在 Finder 中打开数据目录：

```bash
$ open ~/MacSleepMonitorData
```

打开当天报告：

```bash
$ open "$HOME/MacSleepMonitorData/$(date +%F)/report.html"
```

报告只在采集结束后生成。`05:00–08:00` 任务运行期间尚未看到 `report.html` 属于正常情况。

## 查看运行日志

标准日志：

```bash
$ tail -n 100 ~/MacSleepMonitorData/launchd.stdout.log
```

错误日志：

```bash
$ tail -n 100 ~/MacSleepMonitorData/launchd.stderr.log
```

正常日志应包含：

```text
MacSleepMonitor 已启动
监控已停止
统计报告已生成
```

## 睡眠状态的含义

如果 Mac 真正进入睡眠，CPU 不执行普通用户态程序，采集器也会暂停。报告中的空白或 `sampling_gap` 表示系统睡眠或采样线程长时间未运行。

如果盒盖后系统没有真正睡眠，`launchd` 能在 `05:00` 启动采集器，后台进程的 CPU、内存、磁盘、网络和文件数会被记录。

如果 Mac 在 `05:00` 处于真正睡眠，但在 `08:00` 前醒来，macOS 通常会补触发任务，采集器只记录醒来后到 `08:00` 的数据。如果 `08:00` 后才醒来，当天任务会跳过，不会采集错误时间范围。

!!! warning 注意
不要使用 `pmset repeat wakeorpoweron` 强制在 `05:00` 唤醒 Mac。强制唤醒会改变被诊断对象的睡眠行为，使测试结果失去原本意义。
!!!

## 更新程序

收到新版迁移包后：

1. 替换 `Sources`、`scripts`、`Package.swift` 和文档。
2. 重新编译。
3. 再次运行安装脚本。

```bash
$ swift build -c release
```

```bash
$ sudo ./scripts/install-daily-monitor.sh 5 0 08:00 "$HOME/MacSleepMonitorData"
```

重复安装会替换旧二进制并更新原定时任务，不会创建重复任务，也不会删除历史数据。

## 卸载

在项目目录执行：

```bash
$ sudo ./scripts/uninstall-daily-monitor.sh
```

卸载会删除系统级定时配置和已安装的二进制，不会删除 `~/MacSleepMonitorData` 中的历史数据。

## 常见问题

### `swift` 命令不存在

执行 `xcode-select --install` 并完成 Command Line Tools 安装。

### 脚本提示 Permission denied

```bash
$ chmod +x scripts/*.sh
```

### 终端提示开发者无法验证

确认迁移包来自可信的开发 Mac，然后执行：

```bash
$ xattr -dr com.apple.quarantine ~/Projects/MacSleepMonitor
```

### 第二天没有日期目录

依次检查：

```bash
$ date
```

```bash
$ sudo launchctl print system/com.local.macsleepmonitor.daily
```

```bash
$ tail -n 100 ~/MacSleepMonitorData/launchd.stderr.log
```

如果目标 Mac 在整个 `05:00–08:00` 期间关机或保持真正睡眠，并且直到 `08:00` 后才唤醒，当天没有采集目录属于预期结果。

### 有数据库但没有报告

手动重新生成：

```bash
$ sudo .build/release/mac-sleep-monitor report \
  --database "$HOME/MacSleepMonitorData/YYYY-MM-DD/monitor.sqlite" \
  --output "$HOME/MacSleepMonitorData/YYYY-MM-DD/report.html" \
  --bucket 30
```

把 `YYYY-MM-DD` 替换成实际日期。
