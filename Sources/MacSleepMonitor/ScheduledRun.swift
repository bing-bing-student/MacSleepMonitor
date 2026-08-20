import Foundation

struct ScheduledRunConfiguration {
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
    let outputRootURL: URL
    let sampleIntervalSeconds: Double
    let topCount: Int
    let bucketSeconds: Int
}

enum ScheduledRunError: Error, CustomStringConvertible {
    case invalidTimeRange
    case outsideTimeWindow

    var description: String {
        switch self {
        case .invalidTimeRange:
            "定时任务时间范围无效"
        case .outsideTimeWindow:
            "当前时间不在配置的采集时段内，本次任务跳过"
        }
    }
}

enum ScheduledRun {
    static func execute(configuration: ScheduledRunConfiguration) throws {
        let now = Date()
        let calendar = Calendar.current
        guard let startToday = calendar.date(
                bySettingHour: configuration.startHour,
                minute: configuration.startMinute,
                second: 0,
                of: now
              ),
              let endToday = calendar.date(
                bySettingHour: configuration.endHour,
                minute: configuration.endMinute,
                second: 0,
                of: now
              ) else {
            throw ScheduledRunError.invalidTimeRange
        }

        let startMinutes = configuration.startHour * 60 + configuration.startMinute
        let endMinutes = configuration.endHour * 60 + configuration.endMinute
        guard startMinutes != endMinutes else {
            throw ScheduledRunError.invalidTimeRange
        }

        let currentComponents = calendar.dateComponents([.hour, .minute], from: now)
        let currentMinutes = (currentComponents.hour ?? 0) * 60 +
            (currentComponents.minute ?? 0)
        let crossesMidnight = endMinutes < startMinutes
        let window: (start: Date, end: Date)?

        if !crossesMidnight {
            window = now >= startToday && now < endToday
                ? (startToday, endToday)
                : nil
        } else if currentMinutes >= startMinutes {
            window = calendar.date(byAdding: .day, value: 1, to: endToday)
                .map { (startToday, $0) }
        } else if currentMinutes < endMinutes {
            window = calendar.date(byAdding: .day, value: -1, to: startToday)
                .map { ($0, endToday) }
        } else {
            window = nil
        }

        guard let window else {
            print(ScheduledRunError.outsideTimeWindow.description)
            return
        }

        let remaining = window.end.timeIntervalSince(now)
        guard remaining > 1 else {
            print(ScheduledRunError.outsideTimeWindow.description)
            return
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let runDirectory = configuration.outputRootURL
            .appendingPathComponent(
                dayFormatter.string(from: window.start),
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: runDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: runDirectory.path
        )

        let databaseURL = runDirectory.appendingPathComponent("monitor.sqlite")
        let reportURL = runDirectory.appendingPathComponent("report.html")
        let monitorConfiguration = MonitorConfiguration(
            sampleIntervalSeconds: configuration.sampleIntervalSeconds,
            fileDescriptorIntervalSeconds: 10,
            expectedDurationSeconds: remaining,
            topCount: configuration.topCount,
            databaseURL: databaseURL,
            csvDirectoryURL: runDirectory.appendingPathComponent("csv", isDirectory: true),
            includeAllProcesses: false
        )

        print("定时采集目录：\(runDirectory.path)")
        print("计划结束时间：\(window.end)")
        let runner = try MonitorRunner(configuration: monitorConfiguration)
        try runner.run()

        let generator = ReportGenerator(
            databaseURL: databaseURL,
            outputURL: reportURL,
            bucketSeconds: configuration.bucketSeconds
        )
        try generator.generate()
        print("统计报告已生成：\(reportURL.path)")
    }
}
