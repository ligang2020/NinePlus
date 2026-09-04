import Foundation

/// A single, timestamped charging telemetry sample. Optional electrical and
/// thermal values stay optional: the UI must never fabricate unavailable data.
struct ChargingPowerPoint: Codable, Equatable, Identifiable {
    var id: String
    var timestamp: Date
    var power: Double
    var voltage: Double?
    var current: Double?
    var temperature: Double?
    var soc: Double?

    init(
        id: String = UUID().uuidString,
        timestamp: Date,
        power: Double,
        voltage: Double? = nil,
        current: Double? = nil,
        temperature: Double? = nil,
        soc: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.power = power
        self.voltage = voltage
        self.current = current
        self.temperature = temperature
        self.soc = soc
    }
}

enum ChargingSegmentType: String, Codable, Equatable, CaseIterable {
    case startup
    case highPower
    case stable
    case lowPower
    case finishing
    case completed

    var title: String {
        switch self {
        case .startup: return "启动"
        case .highPower: return "高功率"
        case .stable: return "稳定"
        case .lowPower: return "低功率"
        case .finishing: return "降功率"
        case .completed: return "结束"
        }
    }
}

struct ChargingSegment: Codable, Equatable, Identifiable {
    var id: String { "\(type.rawValue)-\(startTime.timeIntervalSince1970)-\(endTime.timeIntervalSince1970)" }
    var startTime: Date
    var endTime: Date
    var duration: TimeInterval
    var averagePower: Double
    var minPower: Double
    var maxPower: Double
    var type: ChargingSegmentType
}

struct ChargingPowerAnalysis: Equatable {
    var points: [ChargingPowerPoint]
    var segments: [ChargingSegment]
    var peakPower: Double?
    var lowPower: Double?
    var averagePower: Double?
    var instantaneousPeak: ChargingPowerPoint?
    var highPowerDuration: TimeInterval
    var highPowerStartTime: Date?
    var highPowerEndTime: Date?
    var lowPowerDuration: TimeInterval
    var lowPowerStartTime: Date?
    var lowPowerEndTime: Date?

    static let empty = ChargingPowerAnalysis(
        points: [], segments: [], peakPower: nil, lowPower: nil, averagePower: nil,
        instantaneousPeak: nil, highPowerDuration: 0, highPowerStartTime: nil,
        highPowerEndTime: nil, lowPowerDuration: 0, lowPowerStartTime: nil,
        lowPowerEndTime: nil
    )
}

/// Deterministic, UI-independent charging phase analysis.
/// The detector smooths only for classification; raw samples remain intact
/// for the chart and live power readout.
enum ChargingPowerAnalyzer {
    static func analyze(_ input: [ChargingPowerPoint]) -> ChargingPowerAnalysis {
        let points = normalized(input)
        guard !points.isEmpty else { return .empty }

        let positive = points.filter { $0.power > 0 }
        guard !positive.isEmpty else {
            return ChargingPowerAnalysis(
                points: points, segments: makeCompletedSegment(from: points), peakPower: nil,
                lowPower: nil, averagePower: nil, instantaneousPeak: nil,
                highPowerDuration: 0, highPowerStartTime: nil, highPowerEndTime: nil,
                lowPowerDuration: 0, lowPowerStartTime: nil, lowPowerEndTime: nil
            )
        }

        let smoothed = medianFilter(positive.map(\.power), radius: 1)
        let rawPeak = positive.map(\.power).max() ?? 0
        let threshold = highThreshold(smoothed, rawPeak: rawPeak)
        let runs = qualifyingRuns(values: smoothed, threshold: threshold, minimumCount: 3)
        let highRange = mergedRange(runs)
        let peak = positive.max { $0.power < $1.power }
        let average = positive.map(\.power).reduce(0, +) / Double(positive.count)

        let segments = makeSegments(points: points, positive: positive, smoothed: smoothed, highRange: highRange, threshold: threshold)
        let highSegments = segments.filter { $0.type == .highPower }
        let lowSegments = segments.filter { $0.type == .startup || $0.type == .lowPower }
        let highStart = highSegments.first?.startTime
        let highEnd = highSegments.last?.endTime
        let lowStart = lowSegments.first?.startTime
        let lowEnd = lowSegments.last?.endTime

        return ChargingPowerAnalysis(
            points: points,
            segments: segments,
            peakPower: peak?.power,
            lowPower: positive.map(\.power).min(),
            averagePower: average,
            // A peak is instantaneous when it was not backed by a qualifying run.
            instantaneousPeak: runs.isEmpty ? peak : (peak.map { point in
                let index = positive.firstIndex(where: { $0.id == point.id }) ?? 0
                return runs.contains { $0.contains(index) } ? nil : point
            } ?? nil),
            highPowerDuration: highSegments.reduce(0) { $0 + $1.duration },
            highPowerStartTime: highStart,
            highPowerEndTime: highEnd,
            lowPowerDuration: lowSegments.reduce(0) { $0 + $1.duration },
            lowPowerStartTime: lowStart,
            lowPowerEndTime: lowEnd
        )
    }

    private static func normalized(_ input: [ChargingPowerPoint]) -> [ChargingPowerPoint] {
        var byTimestamp: [TimeInterval: ChargingPowerPoint] = [:]
        for point in input where point.timestamp.timeIntervalSince1970.isFinite {
            guard point.power.isFinite else { continue }
            let clean = ChargingPowerPoint(
                id: point.id, timestamp: point.timestamp, power: max(point.power, 0),
                voltage: point.voltage, current: point.current,
                temperature: point.temperature, soc: point.soc
            )
            byTimestamp[point.timestamp.timeIntervalSince1970] = clean
        }
        return byTimestamp.values.sorted { $0.timestamp < $1.timestamp }
    }

    private static func medianFilter(_ values: [Double], radius: Int) -> [Double] {
        values.indices.map { index in
            let lower = max(0, index - radius)
            let upper = min(values.count - 1, index + radius)
            return values[lower...upper].sorted()[((upper - lower) / 2)]
        }
    }

    private static func highThreshold(_ values: [Double], rawPeak: Double) -> Double {
        guard let smoothedPeak = values.max(), smoothedPeak > 0, rawPeak > 0 else {
            return .greatestFiniteMagnitude
        }
        let sorted = values.sorted()
        let baseline = sorted[sorted.count / 2]
        // If the raw peak is not materially above the sustained level, there is
        // no separate high-power phase. This prevents a flat 170 W trace from
        // being mislabeled as a high-power run.
        guard rawPeak >= baseline * 1.25 else { return .greatestFiniteMagnitude }
        let percentile = sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.70))]
        // Use the raw peak to keep a single 1691 W spike out of the sustained
        // run after median filtering has correctly flattened it.
        return max(percentile, rawPeak * 0.55)
    }

    private static func qualifyingRuns(values: [Double], threshold: Double, minimumCount: Int) -> [Range<Int>] {
        guard !values.isEmpty else { return [] }
        var result: [Range<Int>] = []
        var start: Int?
        for index in values.indices {
            if values[index] >= threshold {
                start = start ?? index
            } else if let current = start {
                if index - current >= minimumCount { result.append(current..<index) }
                start = nil
            }
        }
        if let current = start, values.count - current >= minimumCount { result.append(current..<values.count) }
        return result
    }

    private static func mergedRange(_ ranges: [Range<Int>]) -> Range<Int>? {
        guard let first = ranges.first, let last = ranges.last else { return nil }
        return first.lowerBound..<last.upperBound
    }

    private static func makeSegments(
        points: [ChargingPowerPoint], positive: [ChargingPowerPoint], smoothed: [Double],
        highRange: Range<Int>?, threshold: Double
    ) -> [ChargingSegment] {
        guard let first = points.first, let last = points.last else { return [] }
        let highStartDate = highRange.flatMap { positive[safe: $0.lowerBound]?.timestamp }
        let highEndDate = highRange.flatMap { positive[safe: max($0.upperBound - 1, $0.lowerBound)]?.timestamp }
        let peakPower = positive.map(\.power).max() ?? 0
        let classificationThreshold = threshold.isFinite ? threshold : max(peakPower * 1.1, 1)
        let taperThreshold = highRange == nil
            ? peakPower * 0.28
            : max(classificationThreshold * 0.68, peakPower * 0.28)
        var classified: [(ChargingPowerPoint, ChargingSegmentType)] = []
        for point in points {
            let type: ChargingSegmentType
            if point.power <= 1 {
                type = .completed
            } else if let highStartDate, point.timestamp < highStartDate {
                type = .startup
            } else if let highEndDate, point.timestamp <= highEndDate {
                type = .highPower
            } else if point.power < taperThreshold {
                type = .finishing
            } else if point.power < classificationThreshold * 0.82 {
                type = .lowPower
            } else {
                type = .stable
            }
            classified.append((point, type))
        }

        var output: [ChargingSegment] = []
        var bucket: [(ChargingPowerPoint, ChargingSegmentType)] = []
        func flush() {
            guard !bucket.isEmpty else { return }
            let values = bucket.map { $0.0.power }.filter { $0 > 0 }
            let start = bucket[0].0.timestamp
            let end = bucket.last?.0.timestamp ?? start
            let type = bucket[0].1
            output.append(ChargingSegment(
                startTime: start, endTime: end, duration: max(end.timeIntervalSince(start), 0),
                averagePower: values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count),
                minPower: values.min() ?? 0, maxPower: values.max() ?? 0, type: type
            ))
            bucket.removeAll(keepingCapacity: true)
        }
        for item in classified {
            if let existing = bucket.first?.1, existing != item.1 { flush() }
            bucket.append(item)
        }
        flush()
        if output.count == 1, output[0].type == .completed, first.timestamp != last.timestamp {
            return makeCompletedSegment(from: points)
        }
        return output
    }

    private static func makeCompletedSegment(from points: [ChargingPowerPoint]) -> [ChargingSegment] {
        guard let first = points.first, let last = points.last else { return [] }
        return [ChargingSegment(startTime: first.timestamp, endTime: last.timestamp,
                                duration: max(last.timestamp.timeIntervalSince(first.timestamp), 0),
                                averagePower: 0, minPower: 0, maxPower: 0, type: .completed)]
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

struct ChargingSession: Codable, Equatable, Identifiable {
    var id: String
    var vehicleSN: String
    var startedAt: Date
    var endedAt: Date
    var points: [ChargingPowerPoint]

    var analysis: ChargingPowerAnalysis { ChargingPowerAnalyzer.analyze(points) }
}
