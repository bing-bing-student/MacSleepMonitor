# MacSleepMonitor

用于定位 Mac 盒盖后异常发热的 Swift 采集器：

1. 使用 macOS 自带的 `launchd` 每天在指定时间启动。
2. 在指定结束时间停止采集并自动生成 HTML 统计图表。

默认安装配置是每天 `05:00–08:00`，以 5 秒间隔采集，数据保存到当前用户主目录的 `MacSleepMonitorData`。五分钟手动测试使用 1 秒间隔。

迁移到另一台 Mac、五分钟测试和定时任务的完整步骤见
[`MIGRATION-SOP.md`](MIGRATION-SOP.md)。

## 快速开始

目标 Mac 首次使用：

```bash
$ xcode-select --install
```

如果 Command Line Tools 已安装，这条命令会提示无需重复安装。

```bash
$ chmod +x scripts/*.sh
```

```bash
$ swift build -c release
```

先运行五分钟测试并自动打开报告：

```bash
$ ./scripts/run-5-minute-test.sh
```

确认报告正常后，安装每天 `05:00–08:00` 的定时任务：

```bash
$ sudo ./scripts/install-daily-monitor.sh 05:00 08:00 "$HOME/MacSleepMonitorData"
```

## 当前能力

- 每进程 CPU 利用率，采用“一个逻辑核心满载为 100%”的语义。
- Resident Memory 和 Physical Footprint。
- 磁盘读取、写入字节速率。
- 每进程网络接收、发送速率，每 5 秒通过 macOS 自带 `nettop` 采样。
- 逻辑写入次数速率。
- 打开文件描述符数量，来自同一次 BSD 进程快照。
- 每项指标独立 Top N，保存名单并集。
- 以 `PID + 进程启动时间` 区分 PID 复用。
- 检测长采样缺口，并在唤醒后重置累计计数基线。
- SQLite WAL 持久化。
- 可选 CSV 输出。
- 从 SQLite 生成离线 HTML 交互图表。
- 使用系统级 `LaunchDaemon` 每天定时运行。
- 每次定时采集结束后自动生成报告。

## 当前边界

- IOKit 精确的 `Sleep`、`DarkWake`、`Wake` 事件。当前版本通过单调时钟采样缺口识别睡眠。
- 普通权限 GUI；当前通过命令行和 HTML 报告操作。
- 按 Bundle ID 聚合浏览器、XPC Service 等辅助进程。

## 首次安装

在本项目文件夹打开终端，依次执行：

```bash
$ swift build -c release
```

只有遇到 SwiftPM 沙箱权限错误时才使用
`swift build -c release --disable-sandbox`。

```bash
$ sudo ./scripts/install-daily-monitor.sh
```

第二条命令会要求输入 Mac 登录密码。输入密码时终端不会显示字符，这是正常现象。

安装完成后，不需要一直开着终端，也不需要每天手动运行。`launchd` 会每天 `05:00` 启动采集，到 `08:00` 自动停止并生成报告。

## 每天查看报告

Finder 中打开：

```text
个人主目录/MacSleepMonitorData/
```

每天一个目录：

```text
MacSleepMonitorData/
├── launchd.stdout.log
├── launchd.stderr.log
└── 2026-08-21/
    ├── monitor.sqlite
    ├── report.html
    └── csv/
        ├── monitor_events.csv
        └── process_samples.csv
```

双击当天目录中的 `report.html` 即可查看。报告完全离线，不需要启动服务器。

图表包括：

- 所有已采集进程的 CPU、内存、磁盘、网络和打开文件时间曲线
- 默认按进程名称聚合，同一时间桶内各实例的指标分别求和
- 可切换“进程实例”视图，以 `名称 · PID` 区分每个实例
- 当前指标的 Top 10 峰值与平均值排名表
- 单击进程名称只显示该进程，再点一次恢复全部曲线
- 鼠标停留在进程名称上可查看可执行路径
- 睡眠或采样中断区间
- 左键拖选时间段放大
- 鼠标滚轮按指针位置缩放
- `Shift` + 拖动平移时间窗口
- 双击图表或点击“重置范围”恢复全时段

## 修改采集时间

安装脚本参数依次是：

```text
开始时间 结束时间 数据目录
```

例如每天凌晨 `04:30–07:30`：

```bash
$ sudo ./scripts/install-daily-monitor.sh 04:30 07:30
```

例如每天 `05:00–08:00`，同时指定其他数据目录：

```bash
$ sudo ./scripts/install-daily-monitor.sh 05:00 08:00 "/Users/你的用户名/Documents/MacMonitorData"
```

重复运行安装命令会更新原来的定时任务，不会创建重复任务。

整体提前一小时：

```bash
$ sudo ./scripts/install-daily-monitor.sh 04:00 07:00
```

结束时间延长两小时：

```bash
$ sudo ./scripts/install-daily-monitor.sh 05:00 10:00
```

精确到分钟：

```bash
$ sudo ./scripts/install-daily-monitor.sh 03:30 07:50
```

跨午夜时，结束时间自动解释为次日。例如：

```bash
$ sudo ./scripts/install-daily-monitor.sh 23:30 02:00
```

定时任务只采集指定进程：

```bash
$ sudo ./scripts/install-daily-monitor.sh \
  05:00 08:00 \
  "$HOME/MacSleepMonitorData" \
  --process node \
  --process "Google Chrome"
```

重复安装时必须再次写出需要跟踪的全部名称；不带 `--process` 重新安装会恢复为仅采集 Top 10 并集。

## 检查任务状态

```bash
$ sudo launchctl print system/com.local.macsleepmonitor.daily
```

确认已安装任务的启动参数，其中 `--interval` 后应为 `5`：

```bash
$ sudo plutil -p /Library/LaunchDaemons/com.local.macsleepmonitor.daily.plist
```

查看运行日志：

```bash
$ tail -n 100 ~/MacSleepMonitorData/launchd.stdout.log
```

查看错误日志：

```bash
$ tail -n 100 ~/MacSleepMonitorData/launchd.stderr.log
```

5 秒定时采样允许正常的系统调度抖动，只有普通采样线程延迟超过 15 秒才记录为缺口；真实睡眠或挂起通过墙上时间与单调时钟的差值独立判断。

## 手动采集

运行五分钟测试并自动生成、打开报告：

```bash
$ ./scripts/run-5-minute-test.sh
```

脚本会先执行 Release 增量构建，确保测试使用当前源码对应的最新二进制。五分钟测试总时长为 5 分钟，内部采样间隔仍为 1 秒；普通调度间隔超过 6 秒才记录为缺口。

只采集指定进程，不再保存其他 Top 10 进程：

```bash
$ ./scripts/run-5-minute-test.sh \
  --process node \
  --process "Google Chrome"
```

`--process` 可重复使用，最多指定 10 个不同名称。名称精确匹配但忽略大小写；同名的所有 PID 都会持续采集。只要提供了该参数，数据库和报告便不包含其他进程；不指定时保持原有 Top 10 并集方式。

持续采集，按 `Ctrl+C` 停止：

```text
$ sudo .build/release/mac-sleep-monitor collect --interval 1 --top 10
```

直接使用采集器只采集指定进程：

```bash
$ sudo .build/release/mac-sleep-monitor collect \
  --interval 1 \
  --top 10 \
  --process node \
  --process Python
```

## 手动生成报告

把已有数据库转换为报告：

```bash
$ .build/release/mac-sleep-monitor report \
  --database ./monitor-data/monitor.sqlite \
  --output ./monitor-data/report.html
```

图表默认按 30 秒聚合。修改为 10 秒：

```bash
$ .build/release/mac-sleep-monitor report \
  --database ./monitor-data/monitor.sqlite \
  --output ./monitor-data/report.html \
  --bucket 10
```

## 卸载任务

```bash
$ sudo ./scripts/uninstall-daily-monitor.sh
```

卸载不会删除历史数据。

## 睡眠行为

如果 Mac 真正进入睡眠，普通程序和 root 程序都不能持续采样。报告会把这段时间显示为空白或采样缺口。

如果盒盖后 Mac 没有睡眠，或者唤醒后持续运行，采集器会继续记录进程指标，这正是需要定位的异常状态。

如果 Mac 在 `05:00` 正在睡眠、但在 `08:00` 前醒来，`launchd` 通常会补触发任务，采集器只采集到当天 `08:00`。如果 `08:00` 后才醒来，当天任务会跳过，不会错误采集到其他时间段。

## 数据解释

`process_samples.cpu_percent` 使用活动监视器类似的语义：单个核心持续满载约为 `100`，多线程进程可能超过 `100`。

`monitor_events.kind = sampling_gap` 表示采样线程长时间没有运行，通常是系统睡眠，也可能是严重调度阻塞。缺口后的第一次采样只建立新基线，不会把睡眠前后的累计 I/O 误算成瞬时尖峰。

CSV、SQLite 和报告中没有记录的进程不代表资源为零，只表示它没有进入任何一项指标的 Top N。报告不会把缺失值补成零，也不会跨睡眠缺口连接折线。

## 查询示例

查看 CPU 峰值：

```bash
$ sqlite3 monitor-data/monitor.sqlite "SELECT datetime(timestamp,'unixepoch','localtime'), p.name, round(cpu_percent,1) FROM process_samples s JOIN processes p USING(stable_key) ORDER BY cpu_percent DESC LIMIT 20;"
```

查看采样缺口：

```bash
$ sqlite3 monitor-data/monitor.sqlite "SELECT datetime(timestamp,'unixepoch','localtime'), kind, round(duration_seconds,1), details FROM monitor_events ORDER BY timestamp;"
```

## 安全说明

安装脚本只会：

- 安装采集器到 `/usr/local/libexec/mac-sleep-monitor`
- 安装定时配置到 `/Library/LaunchDaemons/com.local.macsleepmonitor.daily.plist`
- 在指定目录写入采集数据、报告和日志

它不会修改系统睡眠设置、不会关闭 SIP，也不会绕过 macOS 的安全机制。
