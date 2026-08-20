import Foundation

struct ScheduledRunConfiguration {
    let endHour: Int
    let endMinute: Int
    let outputRootURL: URL
    let sampleIntervalSeconds: Double
    let topCount: Int
    let bucketSeconds: Int
}

enum ScheduledRunError: Error, CustomStringConvertible {
    case invalidEndTime
    case endTimeAlreadyPassed

    var description: String {
        switch self {
        case .invalidEndTime:
            "定时任务结束时间无效"
        case .endTimeAlreadyPassed:
            "今天的采集结束时间已经过去，本次任务跳过"
        }
    }
}

enum ScheduledRun {
    static func execute(configuration: ScheduledRunConfiguration) throws {
        let now = Date()
        let calendar = Calendar.current
        guard let end = calendar.date(
            bySettingHour: configuration.endHour,
            minute: configuration.endMinute,
            second: 0,
            of: now
        ) else {
            throw ScheduledRunError.invalidEndTime
        }

        let remaining = end.timeIntervalSince(now)
        guard remaining > 1 else {
            print(ScheduledRunError.endTimeAlreadyPassed.description)
            return
        }

        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let runDirectory = configuration.outputRootURL
            .appendingPathComponent(dayFormatter.string(from: now), isDirectory: true)
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
        print("计划结束时间：\(end)")
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
