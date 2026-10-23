import Foundation

/// A metric that can be shown in the data overlay.
enum OverlayMetric: String, CaseIterable, Identifiable, Codable, Sendable {
    case heartRate, pace, speed, depth, distance, temperature, altitude, elapsed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heartRate: return "Heart rate"
        case .pace: return "Pace"
        case .speed: return "Speed"
        case .depth: return "Depth"
        case .distance: return "Distance"
        case .temperature: return "Temperature"
        case .altitude: return "Elevation"
        case .elapsed: return "Elapsed time"
        }
    }

    var overlayLabel: String {
        switch self {
        case .heartRate: return "HEART RATE"
        case .pace: return "PACE"
        case .speed: return "SPEED"
        case .depth: return "DEPTH"
        case .distance: return "DISTANCE"
        case .temperature: return "TEMP"
        case .altitude: return "ELEVATION"
        case .elapsed: return "TIME"
        }
    }

    /// Metrics that make sense as a graph.
    var isGraphable: Bool { self != .elapsed }
}

/// A time series of one metric. Times are Unix seconds, sorted ascending.
struct FITSeries: Sendable {
    var times: [Double] = []
    var values: [Double] = []

    var isEmpty: Bool { times.isEmpty }

    mutating func append(_ t: Double, _ v: Double) {
        times.append(t)
        values.append(v)
    }

    /// Linearly interpolated value at `t`. Returns nil outside the series or across gaps larger than `maxGap`.
    func value(at t: Double, maxGap: Double = 15) -> Double? {
        guard let first = times.first, let last = times.last, t >= first - 1, t <= last + 1 else { return nil }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t { lo = mid } else { hi = mid - 1 }
        }
        let i = lo
        if times[i] >= t || i == times.count - 1 { return values[i] }
        let t0 = times[i], t1 = times[i + 1]
        if t1 - t0 > maxGap { return t - t0 < 2 ? values[i] : nil }
        let f = (t - t0) / (t1 - t0)
        return values[i] + (values[i + 1] - values[i]) * f
    }

    /// Centered moving average over a time window (seconds).
    func smoothed(window: Double) -> FITSeries {
        guard times.count > 2, window > 0 else { return self }
        var out = FITSeries()
        out.times = times
        out.values.reserveCapacity(values.count)
        var lo = 0, hi = 0
        var sum = 0.0
        let half = window / 2
        for i in 0..<times.count {
            while hi < times.count, times[hi] <= times[i] + half { sum += values[hi]; hi += 1 }
            while times[lo] < times[i] - half { sum -= values[lo]; lo += 1 }
            out.values.append(sum / Double(hi - lo))
        }
        return out
    }

    func range(from t0: Double, to t1: Double) -> ClosedRange<Double>? {
        var lo = Double.infinity, hi = -Double.infinity
        for (t, v) in zip(times, values) where t >= t0 && t <= t1 {
            lo = min(lo, v)
            hi = max(hi, v)
        }
        return lo <= hi ? lo...hi : nil
    }
}

/// Activity data decoded from a FIT file.
struct FITActivity: Sendable {
    var fileName: String
    var sportName: String
    var isDive: Bool
    var startDate: Date
    var endDate: Date
    /// Local time minus UTC, as recorded by the watch (from the Activity message), if present.
    var utcOffset: TimeInterval?
    var series: [OverlayMetric: FITSeries]

    var availableMetrics: [OverlayMetric] {
        OverlayMetric.allCases.filter { $0 == .elapsed || !(series[$0]?.isEmpty ?? true) }
    }

    func value(_ metric: OverlayMetric, at date: Date) -> Double? {
        let t = date.timeIntervalSince1970
        if metric == .elapsed {
            guard date >= startDate.addingTimeInterval(-1), date <= endDate.addingTimeInterval(1) else { return nil }
            return max(0, t - startDate.timeIntervalSince1970)
        }
        return series[metric]?.value(at: t)
    }

    static func load(url: URL) throws -> FITActivity {
        let data = try Data(contentsOf: url)
        return try decode(data, fileName: url.lastPathComponent)
    }

    static func decode(_ data: Data, fileName: String) throws -> FITActivity {
        let messages = try FITParser.parse(data)

        var hr = FITSeries(), speed = FITSeries(), distance = FITSeries(), depth = FITSeries()
        var temp = FITSeries(), alt = FITSeries()
        var sport: Int?
        var subSport: Int?
        var utcOffset: TimeInterval?

        for msg in messages {
            switch msg.globalNumber {
            case 20: // record
                guard let ts = msg.timestamp else { continue }
                let t = FITParser.date(fromFIT: ts).timeIntervalSince1970
                let f = msg.fields
                if let v = f[3], v > 0 { hr.append(t, v) }
                if let v = f[73] ?? f[6] { speed.append(t, v / 1000) }
                if let v = f[5] { distance.append(t, v / 100) }
                if let v = f[92] { depth.append(t, v / 1000) }
                if let v = f[13] { temp.append(t, v) }
                if let v = f[78] ?? f[2] { alt.append(t, v / 5 - 500) }
            case 18: // session
                if sport == nil, let s = msg.fields[5] { sport = Int(s) }
                if subSport == nil, let s = msg.fields[6] { subSport = Int(s) }
            case 12: // sport
                if sport == nil, let s = msg.fields[0] { sport = Int(s) }
                if subSport == nil, let s = msg.fields[1] { subSport = Int(s) }
            case 34: // activity
                if let ts = msg.timestamp, let local = msg.fields[5] {
                    let offset = local - Double(ts)
                    if abs(offset) <= 14 * 3600 { utcOffset = (offset / 900).rounded() * 900 }
                }
            default:
                break
            }
        }

        // Records are usually sorted, but be safe.
        func sorted(_ s: FITSeries) -> FITSeries {
            guard zip(s.times, s.times.dropFirst()).contains(where: { $0 > $1 }) else { return s }
            let pairs = zip(s.times, s.values).sorted { $0.0 < $1.0 }
            return FITSeries(times: pairs.map(\.0), values: pairs.map(\.1))
        }

        var series: [OverlayMetric: FITSeries] = [:]
        let allTimes = [hr, speed, distance, depth, temp, alt].flatMap(\.times)
        guard let start = allTimes.min(), let end = allTimes.max() else { throw FITError.noRecords }

        if !hr.isEmpty { series[.heartRate] = sorted(hr) }
        if speed.values.contains(where: { $0 > 0 }) {
            let smooth = sorted(speed).smoothed(window: 5)
            series[.speed] = smooth
            series[.pace] = smooth
        }
        if distance.values.contains(where: { $0 > 0 }) { series[.distance] = sorted(distance) }
        if depth.values.contains(where: { $0 > 0.05 }) { series[.depth] = sorted(depth) }
        if !temp.isEmpty { series[.temperature] = sorted(temp) }
        if !alt.isEmpty { series[.altitude] = sorted(alt).smoothed(window: 5) }

        let isDive = sport == 53 || series[.depth] != nil
        return FITActivity(
            fileName: fileName,
            sportName: isDive ? "Diving" : sportName(sport, subSport),
            isDive: isDive,
            startDate: Date(timeIntervalSince1970: start),
            endDate: Date(timeIntervalSince1970: end),
            utcOffset: utcOffset,
            series: series
        )
    }

    private static func sportName(_ sport: Int?, _ subSport: Int?) -> String {
        switch sport {
        case 0: return "Generic"
        case 1: return subSport == 3 ? "Trail running" : "Running"
        case 2: return subSport == 8 ? "Mountain biking" : "Cycling"
        case 5: return "Swimming"
        case 10: return "Training"
        case 11: return "Walking"
        case 12: return "Cross-country skiing"
        case 13: return "Alpine skiing"
        case 14: return "Snowboarding"
        case 15: return "Rowing"
        case 16: return "Mountaineering"
        case 17: return "Hiking"
        case 19: return "Paddling"
        case 37: return "Stand-up paddleboarding"
        case 38: return "Surfing"
        case 41: return "Kayaking"
        case 43: return "Kitesurfing"
        case 53: return "Diving"
        case .none: return "Activity"
        default: return "Activity"
        }
    }
}
