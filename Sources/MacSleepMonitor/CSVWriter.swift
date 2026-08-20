import Foundation

final class CSVWriter {
    private let sampleHandle: FileHandle
    private let eventHandle: FileHandle
    private let dateFormatter = ISO8601DateFormatter()

    init(directoryURL: URL) throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        sampleHandle = try CSVWriter.createFile(
            at: directoryURL.appendingPathComponent("process_samples.csv"),
            header: [
                "timestamp", "pid", "start_time_ns", "name", "executable_path",
                "cpu_percent", "resident_bytes", "physical_footprint_bytes",
                "disk_read_bps", "disk_write_bps", "logical_writes_per_second",
                "network_receive_bps", "network_send_bps",
                "open_file_count", "rank_cpu", "rank_memory", "rank_disk_read",
                "rank_disk_write", "rank_network_receive", "rank_network_send",
                "rank_logical_writes", "rank_open_files"
            ]
        )

        eventHandle = try CSVWriter.createFile(
            at: directoryURL.appendingPathComponent("monitor_events.csv"),
            header: ["timestamp", "kind", "duration_seconds", "details"]
        )
    }

    deinit {
        try? sampleHandle.close()
        try? eventHandle.close()
    }

    func write(samples: [RankedProcessSample]) throws {
        guard !samples.isEmpty else {
            return
        }

        let rows = samples.map { ranked -> String in
            let sample = ranked.sample
            let identityFields = [
                dateFormatter.string(from: sample.timestamp),
                String(sample.identity.pid),
                String(sample.identity.startTimeNanoseconds),
                sample.identity.name,
                sample.identity.executablePath
            ]
            let metricFields = [
                format(sample.cpuPercent),
                String(sample.residentBytes),
                String(sample.physicalFootprintBytes),
                format(sample.diskReadBytesPerSecond),
                format(sample.diskWriteBytesPerSecond),
                format(sample.logicalWritesPerSecond),
                sample.networkReceiveBytesPerSecond.map(format) ?? "",
                sample.networkSendBytesPerSecond.map(format) ?? "",
                sample.openFileCount.map(String.init) ?? ""
            ]
            let rankFields = [
                rankValue(.cpu, from: ranked),
                rankValue(.memory, from: ranked),
                rankValue(.diskRead, from: ranked),
                rankValue(.diskWrite, from: ranked),
                rankValue(.networkReceive, from: ranked),
                rankValue(.networkSend, from: ranked),
                rankValue(.logicalWrites, from: ranked),
                rankValue(.openFiles, from: ranked)
            ]
            return (identityFields + metricFields + rankFields)
            .map(escape)
            .joined(separator: ",")
        }
        try append(rows.joined(separator: "\n") + "\n", to: sampleHandle)
    }

    func write(event: MonitorEvent) throws {
        let row = [
            dateFormatter.string(from: event.timestamp),
            event.kind.rawValue,
            event.durationSeconds.map(format) ?? "",
            event.details
        ]
        .map(escape)
        .joined(separator: ",")
        try append(row + "\n", to: eventHandle)
    }

    private static func createFile(at url: URL, header: [String]) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        if try handle.offset() == 0 {
            let headerData = Data((header.joined(separator: ",") + "\n").utf8)
            try handle.write(contentsOf: headerData)
        }
        return handle
    }

    private func append(_ value: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(value.utf8))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private func rankValue(
        _ metric: RankingMetric,
        from ranked: RankedProcessSample
    ) -> String {
        guard let rank = ranked.ranks[metric] else {
            return ""
        }
        return String(rank)
    }

    private func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
