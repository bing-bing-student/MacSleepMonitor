import Foundation
import SQLite3

enum SQLiteStoreError: Error, CustomStringConvertible {
    case open(String)
    case execute(String)
    case prepare(String)

    var description: String {
        switch self {
        case .open(let message):
            "无法打开数据库：\(message)"
        case .execute(let message):
            "数据库执行失败：\(message)"
        case .prepare(let message):
            "数据库预编译失败：\(message)"
        }
    }
}

final class SQLiteStore {
    private var database: OpaquePointer?
    private let sessionID = UUID().uuidString
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(configuration: MonitorConfiguration) throws {
        try FileManager.default.createDirectory(
            at: configuration.databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if sqlite3_open_v2(
            configuration.databaseURL.path,
            &database,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) != SQLITE_OK {
            throw SQLiteStoreError.open(lastError)
        }

        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA synchronous = NORMAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try createSchema()
        try migrateSchema()
        try insertSession(configuration: configuration)
    }

    deinit {
        sqlite3_close(database)
    }

    func write(samples: [RankedProcessSample], event: MonitorEvent? = nil) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            for ranked in samples {
                try upsertProcess(ranked.sample.identity)
                try insertSample(ranked)
            }
            if let event {
                try insertEvent(event)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    func write(event: MonitorEvent) throws {
        try insertEvent(event)
    }

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                started_at REAL NOT NULL,
                sample_interval_seconds REAL NOT NULL,
                fd_interval_seconds REAL NOT NULL,
                top_count INTEGER NOT NULL,
                include_all_processes INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS processes (
                stable_key TEXT PRIMARY KEY,
                pid INTEGER NOT NULL,
                start_time_ns INTEGER NOT NULL,
                name TEXT NOT NULL,
                executable_path TEXT NOT NULL,
                parent_pid INTEGER NOT NULL,
                user_id INTEGER NOT NULL
            );

            CREATE TABLE IF NOT EXISTS process_samples (
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                stable_key TEXT NOT NULL,
                interval_seconds REAL NOT NULL,
                cpu_percent REAL NOT NULL,
                resident_bytes INTEGER NOT NULL,
                physical_footprint_bytes INTEGER NOT NULL,
                disk_read_bps REAL NOT NULL,
                disk_write_bps REAL NOT NULL,
                network_receive_bps REAL,
                network_send_bps REAL,
                logical_writes_per_second REAL NOT NULL,
                open_file_count INTEGER,
                rank_cpu INTEGER,
                rank_memory INTEGER,
                rank_disk_read INTEGER,
                rank_disk_write INTEGER,
                rank_network_receive INTEGER,
                rank_network_send INTEGER,
                rank_logical_writes INTEGER,
                rank_open_files INTEGER,
                FOREIGN KEY(session_id) REFERENCES sessions(id),
                FOREIGN KEY(stable_key) REFERENCES processes(stable_key)
            );

            CREATE INDEX IF NOT EXISTS idx_samples_time
            ON process_samples(session_id, timestamp);

            CREATE INDEX IF NOT EXISTS idx_samples_process
            ON process_samples(stable_key, timestamp);

            CREATE TABLE IF NOT EXISTS monitor_events (
                session_id TEXT NOT NULL,
                timestamp REAL NOT NULL,
                kind TEXT NOT NULL,
                duration_seconds REAL,
                details TEXT NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id)
            );
            """
        )
    }

    private func migrateSchema() throws {
        let statement = try prepare("PRAGMA table_info(process_samples);")
        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let raw = sqlite3_column_text(statement, 1) {
                columns.insert(String(cString: raw))
            }
        }
        sqlite3_finalize(statement)

        let additions = [
            ("network_receive_bps", "REAL"),
            ("network_send_bps", "REAL"),
            ("rank_network_receive", "INTEGER"),
            ("rank_network_send", "INTEGER")
        ]
        for (name, type) in additions where !columns.contains(name) {
            try execute(
                "ALTER TABLE process_samples ADD COLUMN \(name) \(type);"
            )
        }
    }

    private func insertSession(configuration: MonitorConfiguration) throws {
        let statement = try prepare(
            """
            INSERT INTO sessions (
                id, started_at, sample_interval_seconds,
                fd_interval_seconds, top_count, include_all_processes
            ) VALUES (?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sessionID, index: 1, statement: statement)
        sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, configuration.sampleIntervalSeconds)
        sqlite3_bind_double(statement, 4, configuration.fileDescriptorIntervalSeconds)
        sqlite3_bind_int(statement, 5, Int32(configuration.topCount))
        sqlite3_bind_int(statement, 6, configuration.includeAllProcesses ? 1 : 0)
        try step(statement)
    }

    private func upsertProcess(_ identity: ProcessIdentity) throws {
        let statement = try prepare(
            """
            INSERT INTO processes (
                stable_key, pid, start_time_ns, name,
                executable_path, parent_pid, user_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(stable_key) DO UPDATE SET
                name = excluded.name,
                executable_path = excluded.executable_path,
                parent_pid = excluded.parent_pid,
                user_id = excluded.user_id;
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(identity.stableKey, index: 1, statement: statement)
        sqlite3_bind_int(statement, 2, identity.pid)
        sqlite3_bind_int64(statement, 3, Int64(clamping: identity.startTimeNanoseconds))
        bindText(identity.name, index: 4, statement: statement)
        bindText(identity.executablePath, index: 5, statement: statement)
        sqlite3_bind_int(statement, 6, identity.parentPID)
        sqlite3_bind_int64(statement, 7, Int64(identity.userID))
        try step(statement)
    }

    private func insertSample(_ ranked: RankedProcessSample) throws {
        let statement = try prepare(
            """
            INSERT INTO process_samples (
                session_id, timestamp, stable_key, interval_seconds,
                cpu_percent, resident_bytes, physical_footprint_bytes,
                disk_read_bps, disk_write_bps,
                network_receive_bps, network_send_bps,
                logical_writes_per_second, open_file_count,
                rank_cpu, rank_memory, rank_disk_read, rank_disk_write,
                rank_network_receive, rank_network_send,
                rank_logical_writes, rank_open_files
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        let sample = ranked.sample
        bindText(sessionID, index: 1, statement: statement)
        sqlite3_bind_double(statement, 2, sample.timestamp.timeIntervalSince1970)
        bindText(sample.identity.stableKey, index: 3, statement: statement)
        sqlite3_bind_double(statement, 4, sample.intervalSeconds)
        sqlite3_bind_double(statement, 5, sample.cpuPercent)
        sqlite3_bind_int64(statement, 6, Int64(clamping: sample.residentBytes))
        sqlite3_bind_int64(statement, 7, Int64(clamping: sample.physicalFootprintBytes))
        sqlite3_bind_double(statement, 8, sample.diskReadBytesPerSecond)
        sqlite3_bind_double(statement, 9, sample.diskWriteBytesPerSecond)
        bindOptionalDouble(sample.networkReceiveBytesPerSecond, index: 10, statement: statement)
        bindOptionalDouble(sample.networkSendBytesPerSecond, index: 11, statement: statement)
        sqlite3_bind_double(statement, 12, sample.logicalWritesPerSecond)
        bindOptionalInt(sample.openFileCount, index: 13, statement: statement)
        bindOptionalInt(ranked.ranks[.cpu], index: 14, statement: statement)
        bindOptionalInt(ranked.ranks[.memory], index: 15, statement: statement)
        bindOptionalInt(ranked.ranks[.diskRead], index: 16, statement: statement)
        bindOptionalInt(ranked.ranks[.diskWrite], index: 17, statement: statement)
        bindOptionalInt(ranked.ranks[.networkReceive], index: 18, statement: statement)
        bindOptionalInt(ranked.ranks[.networkSend], index: 19, statement: statement)
        bindOptionalInt(ranked.ranks[.logicalWrites], index: 20, statement: statement)
        bindOptionalInt(ranked.ranks[.openFiles], index: 21, statement: statement)
        try step(statement)
    }

    private func insertEvent(_ event: MonitorEvent) throws {
        let statement = try prepare(
            """
            INSERT INTO monitor_events (
                session_id, timestamp, kind, duration_seconds, details
            ) VALUES (?, ?, ?, ?, ?);
            """
        )
        defer { sqlite3_finalize(statement) }

        bindText(sessionID, index: 1, statement: statement)
        sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
        bindText(event.kind.rawValue, index: 3, statement: statement)
        if let duration = event.durationSeconds {
            sqlite3_bind_double(statement, 4, duration)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        bindText(event.details, index: 5, statement: statement)
        try step(statement)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteStoreError.prepare(lastError)
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? lastError
            sqlite3_free(errorMessage)
            throw SQLiteStoreError.execute(message)
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteStoreError.execute(lastError)
        }
    }

    private func bindText(_ value: String, index: Int32, statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    private func bindOptionalInt(_ value: Int?, index: Int32, statement: OpaquePointer) {
        if let value {
            sqlite3_bind_int64(statement, index, Int64(value))
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bindOptionalDouble(
        _ value: Double?,
        index: Int32,
        statement: OpaquePointer
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private var lastError: String {
        database.map { String(cString: sqlite3_errmsg($0)) } ?? "未知错误"
    }
}
