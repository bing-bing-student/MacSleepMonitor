import Darwin
import Dispatch
import Foundation

final class MonitorRunner: @unchecked Sendable {
    private let configuration: MonitorConfiguration
    private let sampler = ProcessSampler()
    private let store: SQLiteStore
    private let csvWriter: CSVWriter?
    private let stateLock = NSLock()
    private var shouldStop = false
    private var interruptSource: DispatchSourceSignal?
    private var terminationSource: DispatchSourceSignal?

    init(configuration: MonitorConfiguration) throws {
        self.configuration = configuration
        store = try SQLiteStore(configuration: configuration)
        if let csvDirectoryURL = configuration.csvDirectoryURL {
            csvWriter = try CSVWriter(directoryURL: csvDirectoryURL)
        } else {
            csvWriter = nil
        }
    }

    func run() throws {
        installSignalHandler()

        let startedAt = Date()
        var previousWallTime = startedAt
        var previousUptime = DispatchTime.now().uptimeNanoseconds

        let startedEvent = MonitorEvent(
            timestamp: startedAt,
            kind: .monitorStarted,
            durationSeconds: nil,
            details: "采样器启动，pid=\(getpid())"
        )
        try write(event: startedEvent)

        print("MacSleepMonitor 已启动")
        print("数据库：\(configuration.databaseURL.path)")
        if let csvDirectoryURL = configuration.csvDirectoryURL {
            print("CSV：\(csvDirectoryURL.path)")
        }
        print("采样间隔：\(configuration.sampleIntervalSeconds)s，Top \(configuration.topCount)")
        if geteuid() != 0 {
            print("提示：当前不是 root，部分系统进程可能不可见。需要完整采集时请使用 sudo。")
        }
        print("按 Ctrl+C 停止。\n")

        while !stopped {
            let cycleStarted = DispatchTime.now().uptimeNanoseconds
            let now = Date()
            let uptime = cycleStarted
            let monotonicInterval = Double(uptime - previousUptime) / 1_000_000_000
            let wallInterval = now.timeIntervalSince(previousWallTime)
            let suspendedSeconds = wallInterval - monotonicInterval
            let suspensionThreshold = max(
                configuration.sampleIntervalSeconds * 2.5,
                2
            )

            if suspendedSeconds > suspensionThreshold {
                let event = MonitorEvent(
                    timestamp: now,
                    kind: .samplingGap,
                    durationSeconds: wallInterval,
                    details: "单调时钟在墙上时间前进期间暂停，符合系统睡眠或挂起；已重置累计计数基线"
                )
                try write(event: event)
                sampler.resetBaseline()
                print("[\(timeString(now))] 检测到系统睡眠或挂起：\(String(format: "%.1f", wallInterval))s")
            } else if isSamplingGap(monotonicInterval) {
                let event = MonitorEvent(
                    timestamp: now,
                    kind: .samplingGap,
                    durationSeconds: monotonicInterval,
                    details: "采样线程出现长时间调度延迟；已重置累计计数基线"
                )
                try write(event: event)
                sampler.resetBaseline()
                print("[\(timeString(now))] 检测到采样缺口：\(String(format: "%.1f", monotonicInterval))s")
            } else if abs(suspendedSeconds) > 5 {
                let event = MonitorEvent(
                    timestamp: now,
                    kind: .clockChanged,
                    durationSeconds: suspendedSeconds,
                    details: "系统墙上时钟与单调时钟出现偏差"
                )
                try write(event: event)
            }

            let samples = sampler.sample(
                timestamp: now,
                uptimeNanoseconds: uptime,
                intervalSeconds: monotonicInterval,
                fileDescriptorIntervalSeconds: configuration.fileDescriptorIntervalSeconds
            )
            let ranked = TopRanker.rank(
                samples: samples,
                topCount: configuration.topCount,
                includeAllProcesses: configuration.includeAllProcesses
            )
            try store.write(samples: ranked)
            try csvWriter?.write(samples: ranked)

            printSummary(ranked, timestamp: now)

            previousWallTime = now
            previousUptime = uptime

            if let duration = configuration.expectedDurationSeconds,
               now.timeIntervalSince(startedAt) >= duration {
                requestStop()
                continue
            }

            let workSeconds = Double(DispatchTime.now().uptimeNanoseconds - cycleStarted) / 1_000_000_000
            let sleepSeconds = max(configuration.sampleIntervalSeconds - workSeconds, 0.01)
            Thread.sleep(forTimeInterval: sleepSeconds)
        }

        let stoppedEvent = MonitorEvent(
            timestamp: Date(),
            kind: .monitorStopped,
            durationSeconds: Date().timeIntervalSince(startedAt),
            details: "采样器正常停止"
        )
        try write(event: stoppedEvent)
        print("\n监控已停止。")
    }

    func requestStop() {
        stateLock.lock()
        shouldStop = true
        stateLock.unlock()
    }

    private var stopped: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return shouldStop
    }

    private func installSignalHandler() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler { [weak self] in
            self?.requestStop()
        }
        source.resume()
        interruptSource = source

        let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        terminationSource.setEventHandler { [weak self] in
            self?.requestStop()
        }
        terminationSource.resume()
        self.terminationSource = terminationSource
    }

    private func isSamplingGap(_ interval: Double) -> Bool {
        let threshold = max(
            configuration.sampleIntervalSeconds * 3,
            configuration.sampleIntervalSeconds + 5
        )
        return interval > threshold
    }

    private func write(event: MonitorEvent) throws {
        try store.write(event: event)
        try csvWriter?.write(event: event)
    }

    private func printSummary(_ ranked: [RankedProcessSample], timestamp: Date) {
        let topCPU = ranked
            .filter { $0.ranks[.cpu] != nil }
            .sorted { ($0.ranks[.cpu] ?? .max) < ($1.ranks[.cpu] ?? .max) }
            .prefix(3)

        guard !topCPU.isEmpty else {
            print("[\(timeString(timestamp))] 正在建立采样基线…")
            return
        }

        let details = topCPU.map {
            "\($0.sample.identity.name) \(String(format: "%.1f", $0.sample.cpuPercent))%"
        }
        .joined(separator: " | ")
        print("[\(timeString(timestamp))] \(details)")
    }

    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
