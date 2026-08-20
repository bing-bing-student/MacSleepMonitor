import Foundation

enum CommandLineError: Error, CustomStringConvertible {
    case invalidValue(option: String, value: String)
    case missingValue(option: String)
    case unknownOption(String)

    var description: String {
        switch self {
        case .invalidValue(let option, let value):
            "参数 \(option) 的值无效：\(value)"
        case .missingValue(let option):
            "参数 \(option) 缺少值"
        case .unknownOption(let option):
            "未知参数：\(option)"
        }
    }
}

enum PathResolver {
    static func resolve(_ path: String, relativeTo directory: URL) -> URL {
        let expanded = NSString(string: path).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return directory.appendingPathComponent(expanded).standardizedFileURL
    }
}

struct CollectOptions {
    var interval = 1.0
    var fileDescriptorInterval = 10.0
    var duration: Double?
    var topCount = 10
    var databasePath = "./monitor-data/monitor.sqlite"
    var csvDirectoryPath: String? = "./monitor-data/csv"
    var includeAllProcesses = false
    var showHelp = false

    static func parse(_ arguments: [String]) throws -> CollectOptions {
        var options = CollectOptions()
        var index = 0

        func nextValue(for option: String) throws -> String {
            let valueIndex = index + 1
            guard valueIndex < arguments.count else {
                throw CommandLineError.missingValue(option: option)
            }
            index = valueIndex
            return arguments[valueIndex]
        }

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--interval":
                let value = try nextValue(for: argument)
                guard let parsed = Double(value), parsed >= 0.25 else {
                    throw CommandLineError.invalidValue(option: argument, value: value)
                }
                options.interval = parsed
            case "--fd-interval":
                let value = try nextValue(for: argument)
                guard let parsed = Double(value), parsed >= 1 else {
                    throw CommandLineError.invalidValue(option: argument, value: value)
                }
                options.fileDescriptorInterval = parsed
            case "--duration":
                let value = try nextValue(for: argument)
                guard let parsed = Double(value), parsed > 0 else {
                    throw CommandLineError.invalidValue(option: argument, value: value)
                }
                options.duration = parsed
            case "--top":
                let value = try nextValue(for: argument)
                guard let parsed = Int(value), parsed > 0, parsed <= 100 else {
                    throw CommandLineError.invalidValue(option: argument, value: value)
                }
                options.topCount = parsed
            case "--database":
                options.databasePath = try nextValue(for: argument)
            case "--csv-directory":
                options.csvDirectoryPath = try nextValue(for: argument)
            case "--no-csv":
                options.csvDirectoryPath = nil
            case "--all-processes":
                options.includeAllProcesses = true
            case "--help", "-h":
                options.showHelp = true
            default:
                throw CommandLineError.unknownOption(argument)
            }
            index += 1
        }
        return options
    }

    func configuration(currentDirectory: URL) -> MonitorConfiguration {
        MonitorConfiguration(
            sampleIntervalSeconds: interval,
            fileDescriptorIntervalSeconds: fileDescriptorInterval,
            expectedDurationSeconds: duration,
            topCount: topCount,
            databaseURL: PathResolver.resolve(databasePath, relativeTo: currentDirectory),
            csvDirectoryURL: csvDirectoryPath.map {
                PathResolver.resolve($0, relativeTo: currentDirectory)
            },
            includeAllProcesses: includeAllProcesses
        )
    }
}

struct ReportOptions {
    var databasePath = "./monitor-data/monitor.sqlite"
    var outputPath = "./monitor-data/report.html"
    var bucketSeconds = 30

    static func parse(_ arguments: [String]) throws -> ReportOptions {
        var options = ReportOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw CommandLineError.missingValue(option: argument)
                }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--database":
                options.databasePath = try value()
            case "--output":
                options.outputPath = try value()
            case "--bucket":
                let raw = try value()
                guard let parsed = Int(raw), parsed > 0, parsed <= 3600 else {
                    throw CommandLineError.invalidValue(option: argument, value: raw)
                }
                options.bucketSeconds = parsed
            default:
                throw CommandLineError.unknownOption(argument)
            }
            index += 1
        }
        return options
    }
}

struct DailyRunOptions {
    var startTime = "05:00"
    var endTime = "08:00"
    var outputRootPath = "~/MacSleepMonitorData"
    var interval = 5.0
    var topCount = 10
    var bucketSeconds = 30

    static func parse(_ arguments: [String]) throws -> DailyRunOptions {
        var options = DailyRunOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else {
                    throw CommandLineError.missingValue(option: argument)
                }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--start":
                options.startTime = try value()
            case "--end":
                options.endTime = try value()
            case "--output-root":
                options.outputRootPath = try value()
            case "--interval":
                let raw = try value()
                guard let parsed = Double(raw), parsed >= 0.25 else {
                    throw CommandLineError.invalidValue(option: argument, value: raw)
                }
                options.interval = parsed
            case "--top":
                let raw = try value()
                guard let parsed = Int(raw), parsed > 0, parsed <= 100 else {
                    throw CommandLineError.invalidValue(option: argument, value: raw)
                }
                options.topCount = parsed
            case "--bucket":
                let raw = try value()
                guard let parsed = Int(raw), parsed > 0, parsed <= 3600 else {
                    throw CommandLineError.invalidValue(option: argument, value: raw)
                }
                options.bucketSeconds = parsed
            default:
                throw CommandLineError.unknownOption(argument)
            }
            index += 1
        }
        return options
    }

    func configuration(currentDirectory: URL) throws -> ScheduledRunConfiguration {
        func parseTime(_ value: String, option: String) throws -> (Int, Int) {
            let parts = value.split(separator: ":")
            guard parts.count == 2,
                  let hour = Int(parts[0]),
                  let minute = Int(parts[1]),
                  (0...23).contains(hour),
                  (0...59).contains(minute) else {
                throw CommandLineError.invalidValue(option: option, value: value)
            }
            return (hour, minute)
        }

        let (startHour, startMinute) = try parseTime(
            startTime,
            option: "--start"
        )
        let (endHour, endMinute) = try parseTime(
            endTime,
            option: "--end"
        )
        guard startHour != endHour || startMinute != endMinute else {
            throw CommandLineError.invalidValue(
                option: "--start/--end",
                value: "\(startTime) \(endTime)"
            )
        }
        return ScheduledRunConfiguration(
            startHour: startHour,
            startMinute: startMinute,
            endHour: endHour,
            endMinute: endMinute,
            outputRootURL: PathResolver.resolve(
                outputRootPath,
                relativeTo: currentDirectory
            ),
            sampleIntervalSeconds: interval,
            topCount: topCount,
            bucketSeconds: bucketSeconds
        )
    }
}

let help = """
MacSleepMonitor：macOS 进程资源采集器 MVP

用法：
  mac-sleep-monitor collect [采集选项]
  mac-sleep-monitor report [报告选项]
  mac-sleep-monitor scheduled-run [定时任务内部选项]

采集选项：
  --interval <秒>          进程采样间隔，默认 1，最小 0.25
  --fd-interval <秒>       预留的文件详情采样间隔，默认 10
  --duration <秒>          到期自动停止；省略则一直运行
  --top <数量>             每项指标保留前 N 名，默认 10
  --database <路径>        SQLite 文件，默认 ./monitor-data/monitor.sqlite
  --csv-directory <路径>   CSV 输出目录，默认 ./monitor-data/csv
  --no-csv                 不输出 CSV
  --all-processes          保存全部可见进程，而非各指标 Top N 并集

报告选项：
  --database <路径>        输入 SQLite 文件
  --output <路径>          输出 HTML 文件
  --bucket <秒>            图表聚合粒度，默认 30 秒

定时运行选项：
  --start <HH:MM>          开始采集时间
  --end <HH:MM>            停止采集时间；早于开始表示次日
  --output-root <路径>     每日数据根目录
  --interval <秒>          采样间隔
  --top <数量>             每项指标 Top N
  --bucket <秒>            图表聚合粒度

兼容：不写子命令时按 collect 运行。
"""

do {
    var arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--help" || arguments.first == "-h" {
        print(help)
        exit(EXIT_SUCCESS)
    }
    let currentDirectory = URL(
        fileURLWithPath: FileManager.default.currentDirectoryPath,
        isDirectory: true
    )
    let command: String
    if let first = arguments.first,
       ["collect", "report", "scheduled-run"].contains(first) {
        command = first
        arguments.removeFirst()
    } else {
        command = "collect"
    }

    switch command {
    case "collect":
        let options = try CollectOptions.parse(arguments)
        if options.showHelp {
            print(help)
            exit(EXIT_SUCCESS)
        }
        let runner = try MonitorRunner(
            configuration: options.configuration(currentDirectory: currentDirectory)
        )
        try runner.run()
    case "report":
        let options = try ReportOptions.parse(arguments)
        let databaseURL = PathResolver.resolve(
            options.databasePath,
            relativeTo: currentDirectory
        )
        let outputURL = PathResolver.resolve(
            options.outputPath,
            relativeTo: currentDirectory
        )
        try ReportGenerator(
            databaseURL: databaseURL,
            outputURL: outputURL,
            bucketSeconds: options.bucketSeconds
        ).generate()
        print("统计报告已生成：\(outputURL.path)")
    case "scheduled-run":
        let options = try DailyRunOptions.parse(arguments)
        try ScheduledRun.execute(
            configuration: options.configuration(currentDirectory: currentDirectory)
        )
    default:
        throw CommandLineError.unknownOption(command)
    }
} catch {
    FileHandle.standardError.write(Data("错误：\(error)\n\n\(help)\n".utf8))
    exit(EXIT_FAILURE)
}
