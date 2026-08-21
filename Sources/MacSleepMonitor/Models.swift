import Foundation

struct ProcessIdentity: Hashable, Sendable {
    let pid: Int32
    let startTimeNanoseconds: UInt64
    let name: String
    let executablePath: String
    let parentPID: Int32
    let userID: UInt32

    var stableKey: String {
        "\(pid):\(startTimeNanoseconds)"
    }
}

struct ProcessCounters: Sendable {
    let identity: ProcessIdentity
    let userTimeNanoseconds: UInt64
    let systemTimeNanoseconds: UInt64
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let logicalWrites: UInt64
    let openFileCount: Int?
}

struct ProcessSample: Sendable {
    let identity: ProcessIdentity
    let timestamp: Date
    let intervalSeconds: Double
    let cpuPercent: Double
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let networkReceiveBytesPerSecond: Double?
    let networkSendBytesPerSecond: Double?
    let logicalWritesPerSecond: Double
    let openFileCount: Int?
}

enum RankingMetric: String, CaseIterable, Sendable {
    case cpu
    case memory
    case diskRead
    case diskWrite
    case networkReceive
    case networkSend
    case logicalWrites
    case openFiles
}

struct RankedProcessSample: Sendable {
    let sample: ProcessSample
    let ranks: [RankingMetric: Int]
}

enum MonitorEventKind: String, Sendable {
    case monitorStarted = "monitor_started"
    case monitorStopped = "monitor_stopped"
    case samplingGap = "sampling_gap"
    case clockChanged = "clock_changed"
}

struct MonitorEvent: Sendable {
    let timestamp: Date
    let kind: MonitorEventKind
    let durationSeconds: Double?
    let details: String
}

struct MonitorConfiguration: Sendable {
    let sampleIntervalSeconds: Double
    let fileDescriptorIntervalSeconds: Double
    let expectedDurationSeconds: Double?
    let topCount: Int
    let databaseURL: URL
    let csvDirectoryURL: URL?
    let includeAllProcesses: Bool
    let trackedProcessNames: [String]
}

enum ByteFormatter {
    static func rate(_ value: Double) -> String {
        let formatter = Foundation.ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return "\(formatter.string(fromByteCount: Int64(value)))/s"
    }

    static func size(_ value: UInt64) -> String {
        let formatter = Foundation.ByteCountFormatter()
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(clamping: value))
    }
}
