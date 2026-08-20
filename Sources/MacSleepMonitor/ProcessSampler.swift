import Darwin
import Foundation

final class ProcessSampler {
    private var previousCounters: [String: ProcessCounters] = [:]
    private let networkSampler = NetworkSampler(intervalSeconds: 5)
    private let timebaseNumerator: UInt64
    private let timebaseDenominator: UInt64

    init() {
        var timebase = mach_timebase_info_data_t()
        if mach_timebase_info(&timebase) == KERN_SUCCESS,
           timebase.numer > 0,
           timebase.denom > 0 {
            timebaseNumerator = UInt64(timebase.numer)
            timebaseDenominator = UInt64(timebase.denom)
        } else {
            timebaseNumerator = 1
            timebaseDenominator = 1
        }
    }

    func resetBaseline() {
        previousCounters.removeAll(keepingCapacity: true)
        networkSampler.resetBaseline()
    }

    func sample(
        timestamp: Date,
        uptimeNanoseconds: UInt64,
        intervalSeconds: Double,
        fileDescriptorIntervalSeconds: Double
    ) -> [ProcessSample] {
        _ = uptimeNanoseconds
        _ = fileDescriptorIntervalSeconds
        let current = readAllCounters()
        let networkRates = networkSampler.sample(
            counters: current,
            uptimeNanoseconds: uptimeNanoseconds
        )
        var samples: [ProcessSample] = []
        samples.reserveCapacity(current.count)

        for counters in current.values {
            guard let previous = previousCounters[counters.identity.stableKey] else {
                continue
            }

            let cpuDelta = saturatingDelta(
                counters.userTimeNanoseconds + counters.systemTimeNanoseconds,
                previous.userTimeNanoseconds + previous.systemTimeNanoseconds
            )
            let readDelta = saturatingDelta(counters.diskReadBytes, previous.diskReadBytes)
            let writeDelta = saturatingDelta(counters.diskWriteBytes, previous.diskWriteBytes)
            let logicalWriteDelta = saturatingDelta(counters.logicalWrites, previous.logicalWrites)

            let safeInterval = max(intervalSeconds, 0.001)
            let cpuPercent = Double(cpuDelta) / (safeInterval * 1_000_000_000) * 100

            samples.append(
                ProcessSample(
                    identity: counters.identity,
                    timestamp: timestamp,
                    intervalSeconds: safeInterval,
                    cpuPercent: cpuPercent,
                    residentBytes: counters.residentBytes,
                    physicalFootprintBytes: counters.physicalFootprintBytes,
                    diskReadBytesPerSecond: Double(readDelta) / safeInterval,
                    diskWriteBytesPerSecond: Double(writeDelta) / safeInterval,
                    networkReceiveBytesPerSecond: networkRates[counters.identity.stableKey]?.receiveBytesPerSecond,
                    networkSendBytesPerSecond: networkRates[counters.identity.stableKey]?.sendBytesPerSecond,
                    logicalWritesPerSecond: Double(logicalWriteDelta) / safeInterval,
                    openFileCount: counters.openFileCount ?? previous.openFileCount
                )
            )
        }

        previousCounters = current
        return samples
    }

    private func readAllCounters() -> [String: ProcessCounters] {
        var result: [String: ProcessCounters] = [:]
        let pids = listAllProcessIDs()
        result.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            guard let counters = readCounters(pid: pid) else {
                continue
            }
            result[counters.identity.stableKey] = counters
        }
        return result
    }

    private func listAllProcessIDs() -> [pid_t] {
        let estimatedCount = max(Int(proc_listallpids(nil, 0)), 1024)
        var pids = [pid_t](repeating: 0, count: estimatedCount + 256)
        let byteCount = pids.count * MemoryLayout<pid_t>.stride
        let count = pids.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listallpids(buffer.baseAddress, Int32(byteCount))
        }
        guard count > 0 else {
            return []
        }
        return Array(pids.prefix(Int(count)))
    }

    private func readCounters(pid: pid_t) -> ProcessCounters? {
        guard let bsdInfo = readBSDInfo(pid: pid) else {
            return nil
        }

        var usage = rusage_info_v4()
        let usageResult = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            let rebound = UnsafeMutableRawPointer(pointer)
                .assumingMemoryBound(to: rusage_info_t?.self)
            return proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
        }
        guard usageResult == 0 else {
            return nil
        }

        let startNanoseconds =
            bsdInfo.pbi_start_tvsec &* 1_000_000_000 +
            bsdInfo.pbi_start_tvusec &* 1_000
        let fallbackName = stringFromTuple(bsdInfo.pbi_name)
        let commandName = processName(pid: pid)
        let name = commandName.isEmpty ? (fallbackName.isEmpty ? "pid-\(pid)" : fallbackName) : commandName

        let identity = ProcessIdentity(
            pid: pid,
            startTimeNanoseconds: startNanoseconds,
            name: name,
            executablePath: processPath(pid: pid),
            parentPID: Int32(bitPattern: bsdInfo.pbi_ppid),
            userID: bsdInfo.pbi_uid
        )

        return ProcessCounters(
            identity: identity,
            userTimeNanoseconds: ticksToNanoseconds(usage.ri_user_time),
            systemTimeNanoseconds: ticksToNanoseconds(usage.ri_system_time),
            residentBytes: usage.ri_resident_size,
            physicalFootprintBytes: usage.ri_phys_footprint,
            diskReadBytes: usage.ri_diskio_bytesread,
            diskWriteBytes: usage.ri_diskio_byteswritten,
            logicalWrites: usage.ri_logical_writes,
            openFileCount: Int(bsdInfo.pbi_nfiles)
        )
    }

    private func readBSDInfo(pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let bytesRead = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                UnsafeMutableRawPointer(pointer),
                Int32(expectedSize)
            )
        }
        return bytesRead == expectedSize ? info : nil
    }

    private func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return ""
        }
        return stringFromCBuffer(buffer)
    }

    private func processPath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else {
            return ""
        }
        return stringFromCBuffer(buffer)
    }

    private func stringFromCBuffer(_ buffer: [CChar]) -> String {
        let bytes = buffer
            .prefix { $0 != 0 }
            .map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func stringFromTuple<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return ""
            }
            return String(cString: baseAddress.assumingMemoryBound(to: CChar.self))
        }
    }

    private func saturatingDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
        current >= previous ? current - previous : 0
    }

    private func ticksToNanoseconds(_ ticks: UInt64) -> UInt64 {
        let whole = ticks / timebaseDenominator
        let remainder = ticks % timebaseDenominator
        return whole &* timebaseNumerator +
            remainder &* timebaseNumerator / timebaseDenominator
    }
}
