import Foundation
import SQLite3

enum ReportGeneratorError: Error, CustomStringConvertible {
    case openDatabase(String)
    case query(String)
    case noSamples

    var description: String {
        switch self {
        case .openDatabase(let message):
            "无法打开报告数据库：\(message)"
        case .query(let message):
            "报告查询失败：\(message)"
        case .noSamples:
            "数据库中没有可用于生成报告的进程样本"
        }
    }
}

private struct ReportProcessStats: Codable {
    let key: String
    let name: String
    let path: String
    let maxCPU: Double
    let averageCPU: Double
    let maxMemory: Double
    let maxDiskRead: Double
    let maxDiskWrite: Double
    let maxNetworkReceive: Double
    let maxNetworkSend: Double
    let maxOpenFiles: Double
}

private struct ReportPoint: Codable {
    let timestamp: Double
    let cpu: Double
    let memory: Double
    let diskRead: Double
    let diskWrite: Double
    let networkReceive: Double?
    let networkSend: Double?
    let openFiles: Double?
}

private struct ReportSeries: Codable {
    let key: String
    let name: String
    let points: [ReportPoint]
}

private struct ReportEventData: Codable {
    let timestamp: Double
    let kind: String
    let duration: Double?
    let details: String
}

private struct ReportPayload: Codable {
    let generatedAt: String
    let startTime: Double
    let endTime: Double
    let sampleCount: Int
    let processCount: Int
    let bucketSeconds: Int
    let stats: [ReportProcessStats]
    let series: [ReportSeries]
    let events: [ReportEventData]
}

private struct BucketAccumulator {
    var timestampTotal = 0.0
    var cpu = 0.0
    var memory = 0.0
    var diskRead = 0.0
    var diskWrite = 0.0
    var networkReceive = 0.0
    var networkSend = 0.0
    var networkReceiveSamples = 0
    var networkSendSamples = 0
    var openFiles = 0.0
    var openFileSamples = 0
    var count = 0

    mutating func add(
        timestamp: Double,
        cpu: Double,
        memory: Double,
        diskRead: Double,
        diskWrite: Double,
        networkReceive: Double?,
        networkSend: Double?,
        openFiles: Double?
    ) {
        timestampTotal += timestamp
        self.cpu += cpu
        self.memory += memory
        self.diskRead += diskRead
        self.diskWrite += diskWrite
        if let networkReceive {
            self.networkReceive += networkReceive
            networkReceiveSamples += 1
        }
        if let networkSend {
            self.networkSend += networkSend
            networkSendSamples += 1
        }
        if let openFiles {
            self.openFiles += openFiles
            openFileSamples += 1
        }
        count += 1
    }

    func point() -> ReportPoint {
        let divisor = Double(max(count, 1))
        return ReportPoint(
            timestamp: timestampTotal / divisor,
            cpu: cpu / divisor,
            memory: memory / divisor,
            diskRead: diskRead / divisor,
            diskWrite: diskWrite / divisor,
            networkReceive: networkReceiveSamples > 0
                ? networkReceive / Double(networkReceiveSamples)
                : nil,
            networkSend: networkSendSamples > 0
                ? networkSend / Double(networkSendSamples)
                : nil,
            openFiles: openFileSamples > 0 ? openFiles / Double(openFileSamples) : nil
        )
    }
}

final class ReportGenerator {
    private let databaseURL: URL
    private let outputURL: URL
    private let bucketSeconds: Int
    private var database: OpaquePointer?
    private var supportsNetworkMetrics = false

    init(databaseURL: URL, outputURL: URL, bucketSeconds: Int = 30) {
        self.databaseURL = databaseURL
        self.outputURL = outputURL
        self.bucketSeconds = max(bucketSeconds, 1)
    }

    deinit {
        sqlite3_close(database)
    }

    func generate() throws {
        try openDatabase()
        supportsNetworkMetrics = try hasColumn(
            "network_receive_bps",
            in: "process_samples"
        )
        let stats = try loadStats()
        guard !stats.isEmpty else {
            throw ReportGeneratorError.noSamples
        }

        let selectedKeys = selectProcessKeys(stats)
        let summary = try loadSummary()
        let series = try loadSeries(selectedKeys: selectedKeys)
        let events = try loadEvents()
        let payload = ReportPayload(
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            startTime: summary.start,
            endTime: summary.end,
            sampleCount: summary.samples,
            processCount: summary.processes,
            bucketSeconds: bucketSeconds,
            stats: stats.filter { selectedKeys.contains($0.key) },
            series: series,
            events: events
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let jsonData = try encoder.encode(payload)
        var json = String(decoding: jsonData, as: UTF8.self)
        json = json.replacingOccurrences(of: "<", with: "\\u003c")

        let html = makeHTML(payloadJSON: json)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try html.write(to: outputURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: outputURL.path
        )
    }

    private func openDatabase() throws {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            throw ReportGeneratorError.openDatabase("文件不存在：\(databaseURL.path)")
        }
        guard sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK else {
            throw ReportGeneratorError.openDatabase(lastError)
        }
    }

    private func loadStats() throws -> [ReportProcessStats] {
        let networkReceiveExpression = supportsNetworkMetrics
            ? "MAX(COALESCE(s.network_receive_bps, 0))"
            : "0"
        let networkSendExpression = supportsNetworkMetrics
            ? "MAX(COALESCE(s.network_send_bps, 0))"
            : "0"
        let sql = """
        SELECT
            p.stable_key, p.name, p.executable_path,
            MAX(s.cpu_percent), AVG(s.cpu_percent),
            MAX(s.physical_footprint_bytes),
            MAX(s.disk_read_bps), MAX(s.disk_write_bps),
            \(networkReceiveExpression), \(networkSendExpression),
            MAX(COALESCE(s.open_file_count, 0))
        FROM process_samples s
        JOIN processes p USING(stable_key)
        GROUP BY p.stable_key, p.name, p.executable_path;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var rows: [ReportProcessStats] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                ReportProcessStats(
                    key: text(statement, 0),
                    name: text(statement, 1),
                    path: text(statement, 2),
                    maxCPU: sqlite3_column_double(statement, 3),
                    averageCPU: sqlite3_column_double(statement, 4),
                    maxMemory: sqlite3_column_double(statement, 5),
                    maxDiskRead: sqlite3_column_double(statement, 6),
                    maxDiskWrite: sqlite3_column_double(statement, 7),
                    maxNetworkReceive: sqlite3_column_double(statement, 8),
                    maxNetworkSend: sqlite3_column_double(statement, 9),
                    maxOpenFiles: sqlite3_column_double(statement, 10)
                )
            )
        }
        return rows
    }

    private func selectProcessKeys(_ stats: [ReportProcessStats]) -> Set<String> {
        var keys = Set<String>()
        let metrics: [(ReportProcessStats) -> Double] = [
            \.maxCPU,
            \.maxMemory,
            \.maxDiskRead,
            \.maxDiskWrite,
            \.maxNetworkReceive,
            \.maxNetworkSend,
            \.maxOpenFiles
        ]
        for metric in metrics {
            stats.sorted { metric($0) > metric($1) }
                .prefix(5)
                .forEach { keys.insert($0.key) }
        }
        return keys
    }

    private func loadSummary() throws -> (
        start: Double,
        end: Double,
        samples: Int,
        processes: Int
    ) {
        let statement = try prepare(
            """
            SELECT MIN(timestamp), MAX(timestamp), COUNT(*), COUNT(DISTINCT stable_key)
            FROM process_samples;
            """
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw ReportGeneratorError.noSamples
        }
        return (
            sqlite3_column_double(statement, 0),
            sqlite3_column_double(statement, 1),
            Int(sqlite3_column_int64(statement, 2)),
            Int(sqlite3_column_int64(statement, 3))
        )
    }

    private func loadSeries(selectedKeys: Set<String>) throws -> [ReportSeries] {
        guard !selectedKeys.isEmpty else {
            return []
        }

        let placeholders = Array(repeating: "?", count: selectedKeys.count)
            .joined(separator: ",")
        let networkReceiveColumn = supportsNetworkMetrics
            ? "s.network_receive_bps"
            : "NULL"
        let networkSendColumn = supportsNetworkMetrics
            ? "s.network_send_bps"
            : "NULL"
        let statement = try prepare(
            """
            SELECT
                s.timestamp, s.stable_key, p.name,
                s.cpu_percent, s.physical_footprint_bytes,
                s.disk_read_bps, s.disk_write_bps,
                \(networkReceiveColumn), \(networkSendColumn),
                s.open_file_count
            FROM process_samples s
            JOIN processes p USING(stable_key)
            WHERE s.stable_key IN (\(placeholders))
            ORDER BY s.timestamp;
            """
        )
        defer { sqlite3_finalize(statement) }

        for (index, key) in selectedKeys.sorted().enumerated() {
            sqlite3_bind_text(
                statement,
                Int32(index + 1),
                key,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }

        var names: [String: String] = [:]
        var buckets: [String: [Int64: BucketAccumulator]] = [:]

        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = sqlite3_column_double(statement, 0)
            let key = text(statement, 1)
            names[key] = text(statement, 2)
            let bucket = Int64(timestamp) / Int64(bucketSeconds)
            let networkReceive: Double? = sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 7)
            let networkSend: Double? = sqlite3_column_type(statement, 8) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 8)
            let openFiles: Double? = sqlite3_column_type(statement, 9) == SQLITE_NULL
                ? nil
                : sqlite3_column_double(statement, 9)
            buckets[key, default: [:]][bucket, default: BucketAccumulator()].add(
                timestamp: timestamp,
                cpu: sqlite3_column_double(statement, 3),
                memory: sqlite3_column_double(statement, 4),
                diskRead: sqlite3_column_double(statement, 5),
                diskWrite: sqlite3_column_double(statement, 6),
                networkReceive: networkReceive,
                networkSend: networkSend,
                openFiles: openFiles
            )
        }

        return buckets.map { key, processBuckets in
            let points = processBuckets
                .sorted { $0.key < $1.key }
                .map { _, accumulator in
                    accumulator.point()
                }
            return ReportSeries(
                key: key,
                name: names[key] ?? key,
                points: points
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func loadEvents() throws -> [ReportEventData] {
        let statement = try prepare(
            """
            SELECT timestamp, kind, duration_seconds, details
            FROM monitor_events
            ORDER BY timestamp;
            """
        )
        defer { sqlite3_finalize(statement) }

        var rows: [ReportEventData] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append(
                ReportEventData(
                    timestamp: sqlite3_column_double(statement, 0),
                    kind: text(statement, 1),
                    duration: sqlite3_column_type(statement, 2) == SQLITE_NULL
                        ? nil
                        : sqlite3_column_double(statement, 2),
                    details: text(statement, 3)
                )
            )
        }
        return rows
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let summary = sql
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? "SQL"
            throw ReportGeneratorError.query("\(lastError)；语句：\(summary)")
        }
        return statement
    }

    private func hasColumn(_ column: String, in table: String) throws -> Bool {
        let statement = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if text(statement, 1) == column {
                return true
            }
        }
        return false
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: raw)
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
    }

    private func makeHTML(payloadJSON: String) -> String {
        """
        <!doctype html>
        <html lang="zh-CN">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>MacSleepMonitor 诊断报告</title>
        <style>
        :root {
          color-scheme: dark;
          --bg: #0b1014;
          --panel: #12191f;
          --panel-2: #172129;
          --line: #293741;
          --text: #edf3f5;
          --muted: #91a3ad;
          --accent: #66d4c2;
          --warning: #f2b45b;
          --series-1: #66d4c2;
          --series-2: #e8c56a;
          --series-3: #7fa6ff;
          --series-4: #e9897e;
          --series-5: #b39ddb;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background:
            linear-gradient(rgba(255,255,255,.025) 1px, transparent 1px),
            linear-gradient(90deg, rgba(255,255,255,.025) 1px, transparent 1px),
            var(--bg);
          background-size: 32px 32px;
          color: var(--text);
          font-family: "Avenir Next", "PingFang SC", sans-serif;
        }
        main { width: min(1320px, calc(100% - 40px)); margin: 0 auto; padding: 48px 0 72px; }
        header { display: grid; grid-template-columns: 1fr auto; align-items: end; gap: 24px; margin-bottom: 28px; }
        .eyebrow { color: var(--accent); font: 600 12px/1.4 ui-monospace, monospace; letter-spacing: .14em; text-transform: uppercase; }
        h1 { margin: 8px 0 0; font: 500 clamp(28px,5vw,54px)/1.05 Georgia, "Songti SC", serif; }
        .range { color: var(--muted); text-align: right; font: 500 13px/1.6 ui-monospace, monospace; }
        .metrics { display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px; margin-bottom: 12px; }
        .metric { padding: 18px; border: 1px solid var(--line); background: rgba(18,25,31,.92); }
        .metric span { display: block; color: var(--muted); font-size: 12px; letter-spacing: .06em; }
        .metric strong { display: block; margin-top: 8px; font: 500 24px/1 ui-monospace, monospace; }
        .panel { border: 1px solid var(--line); background: rgba(18,25,31,.96); }
        .toolbar { display: flex; justify-content: space-between; gap: 16px; padding: 16px 18px; border-bottom: 1px solid var(--line); }
        .tabs { display: flex; gap: 6px; flex-wrap: wrap; }
        button {
          appearance: none; border: 1px solid transparent; border-radius: 999px;
          padding: 7px 12px; color: var(--muted); background: transparent;
          font: 600 12px/1 "Avenir Next", "PingFang SC", sans-serif; cursor: pointer;
        }
        button:hover { color: var(--text); border-color: var(--line); }
        button.active { color: #07110f; background: var(--accent); }
        .unit { align-self: center; color: var(--muted); font: 500 12px/1 ui-monospace, monospace; }
        .chart-wrap { position: relative; height: 440px; padding: 18px; }
        canvas { display: block; width: 100%; height: 100%; }
        .tooltip {
          position: absolute; display: none; pointer-events: none; min-width: 180px;
          padding: 10px 12px; border: 1px solid var(--line); background: #0c1217;
          box-shadow: 0 16px 50px rgba(0,0,0,.35); font-size: 12px;
        }
        .tooltip time { display: block; margin-bottom: 7px; color: var(--muted); font-family: ui-monospace, monospace; }
        .tooltip-row { display: flex; justify-content: space-between; gap: 16px; padding: 3px 0; }
        .tooltip-row i { width: 8px; height: 8px; border-radius: 50%; display: inline-block; margin-right: 7px; }
        .legend { display: flex; flex-wrap: wrap; gap: 8px 16px; padding: 0 18px 18px; }
        .legend button { border-radius: 0; padding: 4px 0; }
        .legend button.off { opacity: .35; text-decoration: line-through; }
        .legend i { width: 9px; height: 9px; display: inline-block; margin-right: 7px; }
        .table-panel { margin-top: 12px; overflow-x: auto; }
        table { width: 100%; border-collapse: collapse; min-width: 1040px; }
        th, td { padding: 13px 16px; border-bottom: 1px solid var(--line); text-align: right; }
        th { color: var(--muted); font-size: 11px; letter-spacing: .06em; text-transform: uppercase; }
        th:first-child, td:first-child { text-align: left; }
        td { font: 500 12px/1.4 ui-monospace, monospace; }
        td:first-child { font-family: "Avenir Next", "PingFang SC", sans-serif; }
        .badge { color: var(--warning); }
        footer { margin-top: 14px; color: var(--muted); font-size: 12px; line-height: 1.7; }
        @media(max-width:760px) {
          main { width: min(100% - 24px, 1320px); padding-top: 28px; }
          header { grid-template-columns: 1fr; }
          .range { text-align: left; }
          .metrics { grid-template-columns: repeat(2, 1fr); }
          .chart-wrap { height: 340px; padding: 8px; }
          .toolbar { align-items: flex-start; flex-direction: column; }
        }
        </style>
        </head>
        <body>
        <main>
          <header>
            <div><div class="eyebrow">MacSleepMonitor / Diagnostic log</div><h1>睡眠时段资源报告</h1></div>
            <div class="range" id="range"></div>
          </header>
          <section class="metrics">
            <div class="metric"><span>采样记录</span><strong id="sampleCount">—</strong></div>
            <div class="metric"><span>入榜进程</span><strong id="processCount">—</strong></div>
            <div class="metric"><span>监控时长</span><strong id="duration">—</strong></div>
            <div class="metric"><span>睡眠缺口</span><strong id="gapCount">—</strong></div>
          </section>
          <section class="panel">
            <div class="toolbar">
              <div class="tabs" id="tabs"></div>
              <div class="unit" id="unit"></div>
            </div>
            <div class="chart-wrap">
              <canvas id="chart"></canvas>
              <div class="tooltip" id="tooltip"></div>
            </div>
            <div class="legend" id="legend"></div>
          </section>
          <section class="panel table-panel">
            <table>
              <thead><tr><th>进程</th><th>峰值 CPU</th><th>平均 CPU</th><th>峰值内存</th><th>峰值磁盘读</th><th>峰值磁盘写</th><th>峰值网络收</th><th>峰值网络发</th><th>最多文件</th></tr></thead>
              <tbody id="ranking"></tbody>
            </table>
          </section>
          <footer>
            曲线只连接连续采样点；灰色区域表示检测到的采样缺口。进程未进入某项 Top N 时数据可能缺失，不会按 0 处理。
          </footer>
        </main>
        <script>
        const data = \(payloadJSON);
        const metrics = {
          cpu: { label: "CPU", unit: "%", field: "cpu", stat: "maxCPU", format: v => v.toFixed(1) + "%" },
          memory: { label: "内存", unit: "MiB", field: "memory", stat: "maxMemory", format: v => (v / 1048576).toFixed(1) + " MiB" },
          diskRead: { label: "磁盘读取", unit: "MiB/s", field: "diskRead", stat: "maxDiskRead", format: v => (v / 1048576).toFixed(2) + " MiB/s" },
          diskWrite: { label: "磁盘写入", unit: "MiB/s", field: "diskWrite", stat: "maxDiskWrite", format: v => (v / 1048576).toFixed(2) + " MiB/s" },
          networkReceive: { label: "网络接收", unit: "MiB/s", field: "networkReceive", stat: "maxNetworkReceive", format: v => (v / 1048576).toFixed(2) + " MiB/s" },
          networkSend: { label: "网络发送", unit: "MiB/s", field: "networkSend", stat: "maxNetworkSend", format: v => (v / 1048576).toFixed(2) + " MiB/s" },
          openFiles: { label: "打开文件", unit: "个", field: "openFiles", stat: "maxOpenFiles", format: v => Math.round(v) + " 个" }
        };
        const colors = ["#66d4c2","#e8c56a","#7fa6ff","#e9897e","#b39ddb"];
        const state = { metric: "cpu", hidden: new Set(), visible: [] };
        const canvas = document.querySelector("#chart");
        const ctx = canvas.getContext("2d");
        const tooltip = document.querySelector("#tooltip");
        const chartWrap = canvas.parentElement;
        const fmtTime = t => new Date(t * 1000).toLocaleString("zh-CN", { hour12: false });
        const fmtDuration = seconds => {
          if (seconds < 60) return `${Math.max(0, Math.round(seconds))}s`;
          const h = Math.floor(seconds / 3600);
          const m = Math.floor((seconds % 3600) / 60);
          if (h === 0) return `${m}m`;
          return `${h}h ${m}m`;
        };
        document.querySelector("#sampleCount").textContent = data.sampleCount.toLocaleString();
        document.querySelector("#processCount").textContent = data.processCount.toLocaleString();
        document.querySelector("#duration").textContent = fmtDuration(Math.max(0, data.endTime - data.startTime));
        const gaps = data.events.filter(event =>
          event.kind === "sampling_gap" ||
          (event.kind === "clock_changed" && event.duration > 5)
        );
        document.querySelector("#gapCount").textContent = gaps.length;
        document.querySelector("#range").innerHTML = `${fmtTime(data.startTime)}<br>${fmtTime(data.endTime)}`;

        const tabs = document.querySelector("#tabs");
        Object.entries(metrics).forEach(([key, metric]) => {
          const button = document.createElement("button");
          button.textContent = metric.label;
          button.dataset.metric = key;
          button.addEventListener("click", () => setMetric(key));
          tabs.appendChild(button);
        });

        function topKeys(metricKey) {
          const metric = metrics[metricKey];
          return [...data.stats].sort((a,b) => b[metric.stat] - a[metric.stat]).slice(0,5).map(row => row.key);
        }

        function setMetric(metricKey) {
          state.metric = metricKey;
          state.hidden.clear();
          state.visible = topKeys(metricKey);
          document.querySelectorAll("#tabs button").forEach(button => button.classList.toggle("active", button.dataset.metric === metricKey));
          document.querySelector("#unit").textContent = metrics[metricKey].unit;
          buildLegend();
          buildTable();
          draw();
        }

        function buildLegend() {
          const legend = document.querySelector("#legend");
          legend.innerHTML = "";
          state.visible.forEach((key, index) => {
            const series = data.series.find(item => item.key === key);
            if (!series) return;
            const button = document.createElement("button");
            button.innerHTML = `<i style="background:${colors[index]}"></i>${series.name}`;
            button.addEventListener("click", () => {
              state.hidden.has(key) ? state.hidden.delete(key) : state.hidden.add(key);
              button.classList.toggle("off", state.hidden.has(key));
              draw();
            });
            legend.appendChild(button);
          });
        }

        function buildTable() {
          const body = document.querySelector("#ranking");
          body.innerHTML = "";
          const metric = metrics[state.metric];
          [...data.stats].sort((a,b) => b[metric.stat] - a[metric.stat]).slice(0,10).forEach((row,index) => {
            const tr = document.createElement("tr");
            tr.innerHTML = `<td>${index + 1}. ${escapeHTML(row.name)}</td><td>${row.maxCPU.toFixed(1)}%</td><td>${row.averageCPU.toFixed(1)}%</td><td>${(row.maxMemory/1048576).toFixed(1)} MiB</td><td>${(row.maxDiskRead/1048576).toFixed(2)} MiB/s</td><td>${(row.maxDiskWrite/1048576).toFixed(2)} MiB/s</td><td>${(row.maxNetworkReceive/1048576).toFixed(2)} MiB/s</td><td>${(row.maxNetworkSend/1048576).toFixed(2)} MiB/s</td><td>${Math.round(row.maxOpenFiles)}</td>`;
            body.appendChild(tr);
          });
        }

        function escapeHTML(value) {
          const div = document.createElement("div");
          div.textContent = value;
          return div.innerHTML;
        }

        function resize() {
          const rect = canvas.getBoundingClientRect();
          const dpr = Math.min(window.devicePixelRatio || 1, 2);
          canvas.width = Math.round(rect.width * dpr);
          canvas.height = Math.round(rect.height * dpr);
          ctx.setTransform(dpr,0,0,dpr,0,0);
          draw();
        }

        function draw() {
          const width = canvas.clientWidth;
          const height = canvas.clientHeight;
          if (!width || !height) return;
          ctx.clearRect(0,0,width,height);
          const plot = { left: 60, top: 20, right: width - 18, bottom: height - 38 };
          const metric = metrics[state.metric];
          const shown = state.visible
            .filter(key => !state.hidden.has(key))
            .map(key => data.series.find(item => item.key === key))
            .filter(Boolean);
          const values = shown.flatMap(series => series.points.map(point => point[metric.field]).filter(value => value != null && Number.isFinite(value)));
          const yMax = Math.max(...values, 1) * 1.12;
          const xMin = data.startTime;
          const xMax = Math.max(data.endTime, xMin + 1);
          const x = value => plot.left + (value - xMin) / (xMax - xMin) * (plot.right - plot.left);
          const y = value => plot.bottom - value / yMax * (plot.bottom - plot.top);
          ctx.font = '11px ui-monospace, monospace';
          ctx.fillStyle = "#91a3ad";
          ctx.strokeStyle = "#293741";
          ctx.lineWidth = 1;
          for (let i=0;i<=4;i++) {
            const yy = plot.top + (plot.bottom-plot.top) * i/4;
            ctx.beginPath(); ctx.moveTo(plot.left,yy); ctx.lineTo(plot.right,yy); ctx.stroke();
            const value = yMax * (1-i/4);
            ctx.fillText(metric.format(value), 4, yy + 4);
          }
          ctx.save();
          ctx.beginPath();
          ctx.rect(
            plot.left,
            plot.top,
            plot.right - plot.left,
            plot.bottom - plot.top
          );
          ctx.clip();
          gaps.forEach(gap => {
            if (!gap.duration) return;
            const start = Math.max(xMin, gap.timestamp - gap.duration);
            const end = Math.min(xMax, gap.timestamp);
            if (end <= start) return;
            ctx.fillStyle = "rgba(145,163,173,.12)";
            ctx.fillRect(x(start), plot.top, x(end)-x(start), plot.bottom-plot.top);
          });
          shown.forEach((series,index) => {
            ctx.strokeStyle = colors[state.visible.indexOf(series.key) % colors.length];
            ctx.lineWidth = 2;
            ctx.beginPath();
            let previous = null;
            series.points.forEach(point => {
              const value = point[metric.field];
              if (value == null || !Number.isFinite(value)) { previous = null; return; }
              const shouldBreak = previous && point.timestamp - previous.timestamp > data.bucketSeconds * 2.5;
              if (!previous || shouldBreak) ctx.moveTo(x(point.timestamp), y(value));
              else ctx.lineTo(x(point.timestamp), y(value));
              previous = point;
            });
            ctx.stroke();
            ctx.fillStyle = colors[state.visible.indexOf(series.key) % colors.length];
            series.points.forEach(point => {
              const value = point[metric.field];
              if (value == null || !Number.isFinite(value)) return;
              ctx.beginPath();
              ctx.arc(x(point.timestamp), y(value), 2.5, 0, Math.PI * 2);
              ctx.fill();
            });
          });
          ctx.restore();
          ctx.fillStyle = "#91a3ad";
          ctx.textAlign = "center";
          for (let i=0;i<=4;i++) {
            const timestamp = xMin + (xMax-xMin)*i/4;
            const shortRange = xMax - xMin < 600;
            ctx.fillText(new Date(timestamp*1000).toLocaleTimeString("zh-CN",{hour:"2-digit",minute:"2-digit",second:shortRange?"2-digit":undefined,hour12:false}), x(timestamp), height-12);
          }
          ctx.textAlign = "left";
        }

        canvas.addEventListener("mousemove", event => {
          const rect = canvas.getBoundingClientRect();
          const plotLeft = 60, plotRight = rect.width - 18;
          if (event.offsetX < plotLeft || event.offsetX > plotRight) { tooltip.style.display = "none"; return; }
          const timestamp = data.startTime + (event.offsetX-plotLeft)/(plotRight-plotLeft)*(data.endTime-data.startTime);
          const metric = metrics[state.metric];
          const rows = [];
          state.visible.filter(key => !state.hidden.has(key)).forEach((key,index) => {
            const series = data.series.find(item => item.key === key);
            if (!series?.points.length) return;
            const point = series.points.reduce((best,current) => Math.abs(current.timestamp-timestamp) < Math.abs(best.timestamp-timestamp) ? current : best);
            const value = point[metric.field];
            if (value == null || Math.abs(point.timestamp-timestamp) > data.bucketSeconds*2.5) return;
            rows.push({ name: series.name, value, color: colors[index], timestamp: point.timestamp });
          });
          if (!rows.length) { tooltip.style.display = "none"; return; }
          tooltip.innerHTML = `<time>${fmtTime(rows[0].timestamp)}</time>` + rows.map(row => `<div class="tooltip-row"><span><i style="background:${row.color}"></i>${escapeHTML(row.name)}</span><b>${metric.format(row.value)}</b></div>`).join("");
          tooltip.style.display = "block";
          const left = Math.min(Math.max(event.offsetX + 14, 100), rect.width - 100);
          tooltip.style.left = `${left}px`;
          tooltip.style.top = `${Math.max(event.offsetY - 8, 20)}px`;
        });
        canvas.addEventListener("mouseleave", () => tooltip.style.display = "none");
        window.addEventListener("resize", resize);
        setMetric("cpu");
        resize();
        </script>
        </body>
        </html>
        """
    }
}
