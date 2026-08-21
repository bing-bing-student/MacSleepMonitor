import Foundation

enum TopRanker {
    static func rank(
        samples: [ProcessSample],
        topCount: Int,
        includeAllProcesses: Bool,
        trackedProcessNames: [String]
    ) -> [RankedProcessSample] {
        guard !samples.isEmpty else {
            return []
        }

        var ranksByKey: [String: [RankingMetric: Int]] = [:]

        rank(samples, metric: .cpu, topCount: topCount, value: \.cpuPercent, into: &ranksByKey)
        rank(samples, metric: .memory, topCount: topCount, value: { Double($0.physicalFootprintBytes) }, into: &ranksByKey)
        rank(samples, metric: .diskRead, topCount: topCount, value: \.diskReadBytesPerSecond, into: &ranksByKey)
        rank(samples, metric: .diskWrite, topCount: topCount, value: \.diskWriteBytesPerSecond, into: &ranksByKey)
        rank(
            samples,
            metric: .networkReceive,
            topCount: topCount,
            value: { $0.networkReceiveBytesPerSecond ?? -1 },
            into: &ranksByKey
        )
        rank(
            samples,
            metric: .networkSend,
            topCount: topCount,
            value: { $0.networkSendBytesPerSecond ?? -1 },
            into: &ranksByKey
        )
        rank(samples, metric: .logicalWrites, topCount: topCount, value: \.logicalWritesPerSecond, into: &ranksByKey)
        rank(
            samples,
            metric: .openFiles,
            topCount: topCount,
            value: { Double($0.openFileCount ?? -1) },
            into: &ranksByKey
        )

        let normalizedTrackedNames = Set(
            trackedProcessNames.map { $0.lowercased() }
        )

        return samples.compactMap { sample in
            let ranks = ranksByKey[sample.identity.stableKey] ?? [:]
            let isTracked = normalizedTrackedNames.contains(
                sample.identity.name.lowercased()
            )
            let shouldInclude = normalizedTrackedNames.isEmpty
                ? (includeAllProcesses || !ranks.isEmpty)
                : isTracked
            guard shouldInclude else {
                return nil
            }
            return RankedProcessSample(sample: sample, ranks: ranks)
        }
        .sorted {
            if $0.sample.cpuPercent == $1.sample.cpuPercent {
                return $0.sample.identity.name.localizedStandardCompare($1.sample.identity.name) == .orderedAscending
            }
            return $0.sample.cpuPercent > $1.sample.cpuPercent
        }
    }

    private static func rank(
        _ samples: [ProcessSample],
        metric: RankingMetric,
        topCount: Int,
        value: (ProcessSample) -> Double,
        into ranksByKey: inout [String: [RankingMetric: Int]]
    ) {
        let sorted = samples
            .filter { value($0).isFinite && value($0) >= 0 }
            .sorted {
                let left = value($0)
                let right = value($1)
                if left == right {
                    return $0.identity.stableKey < $1.identity.stableKey
                }
                return left > right
            }

        for (offset, sample) in sorted.prefix(max(topCount, 0)).enumerated() {
            ranksByKey[sample.identity.stableKey, default: [:]][metric] = offset + 1
        }
    }
}
