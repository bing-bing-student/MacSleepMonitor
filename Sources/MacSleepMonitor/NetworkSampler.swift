import Foundation

struct NetworkRate {
    let receiveBytesPerSecond: Double
    let sendBytesPerSecond: Double
}

final class NetworkSampler {
    private struct Snapshot {
        let stableKey: String
        let bytesIn: UInt64
        let bytesOut: UInt64
    }

    private var previousByPID: [Int32: Snapshot] = [:]
    private var lastSampleUptime: UInt64?
    private let intervalSeconds: Double

    init(intervalSeconds: Double = 5) {
        self.intervalSeconds = max(intervalSeconds, 1)
    }

    func resetBaseline() {
        previousByPID.removeAll(keepingCapacity: true)
        lastSampleUptime = nil
    }

    func sample(
        counters: [String: ProcessCounters],
        uptimeNanoseconds: UInt64
    ) -> [String: NetworkRate] {
        if let lastSampleUptime {
            let elapsed = Double(uptimeNanoseconds - lastSampleUptime) / 1_000_000_000
            guard elapsed >= intervalSeconds else {
                return [:]
            }
        }

        guard let rawSnapshots = readNettop() else {
            return [:]
        }

        let identitiesByPID = Dictionary(
            uniqueKeysWithValues: counters.values.map {
                ($0.identity.pid, $0.identity)
            }
        )
        let elapsed: Double? = lastSampleUptime.map {
            Double(uptimeNanoseconds - $0) / 1_000_000_000
        }
        var currentByPID: [Int32: Snapshot] = [:]
        var rates: [String: NetworkRate] = [:]

        for (pid, totals) in rawSnapshots {
            guard let identity = identitiesByPID[pid] else {
                continue
            }
            let current = Snapshot(
                stableKey: identity.stableKey,
                bytesIn: totals.bytesIn,
                bytesOut: totals.bytesOut
            )
            currentByPID[pid] = current

            guard let elapsed,
                  elapsed > 0,
                  let previous = previousByPID[pid],
                  previous.stableKey == identity.stableKey else {
                continue
            }
            rates[identity.stableKey] = NetworkRate(
                receiveBytesPerSecond: Double(delta(current.bytesIn, previous.bytesIn)) / elapsed,
                sendBytesPerSecond: Double(delta(current.bytesOut, previous.bytesOut)) / elapsed
            )
        }

        previousByPID = currentByPID
        lastSampleUptime = uptimeNanoseconds
        return rates
    }

    private func readNettop() -> [Int32: (bytesIn: UInt64, bytesOut: UInt64)]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        process.arguments = [
            "-P", "-L", "1",
            "-J", "bytes_in,bytes_out",
            "-x"
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return parse(String(decoding: data, as: UTF8.self))
        } catch {
            return nil
        }
    }

    private func parse(
        _ output: String
    ) -> [Int32: (bytesIn: UInt64, bytesOut: UInt64)] {
        var result: [Int32: (bytesIn: UInt64, bytesOut: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline).dropFirst() {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 3,
                  let dot = columns[0].lastIndex(of: "."),
                  let pid = Int32(columns[0][columns[0].index(after: dot)...]),
                  let bytesIn = UInt64(columns[1]),
                  let bytesOut = UInt64(columns[2]) else {
                continue
            }
            result[pid] = (bytesIn, bytesOut)
        }
        return result
    }

    private func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }
}
