import Foundation
import CoreMedia

/// A part of the source video that is removed from the output.
struct CutRange: Identifiable, Hashable, Sendable {
    var id = UUID()
    var start: Double
    var end: Double

    var duration: Double { end - start }
}

/// Trim and cut decisions, expressed in source-video seconds.
///
/// The output is `[trimStart, trimEnd]` minus every cut. "Output time" is the time in the edited video.
struct EditTimeline: Equatable, Sendable {
    static let minimumSegment = 0.05

    var sourceDuration: Double
    var trimStart: Double = 0
    var trimEnd: Double
    private(set) var cuts: [CutRange] = []

    init(sourceDuration: Double) {
        self.sourceDuration = sourceDuration
        self.trimEnd = sourceDuration
    }

    /// Source ranges that make it into the output, in order.
    var keptRanges: [ClosedRange<Double>] {
        var result: [ClosedRange<Double>] = []
        var cursor = trimStart
        for cut in cuts where cut.end > trimStart && cut.start < trimEnd {
            if cut.start > cursor { result.append(cursor...cut.start) }
            cursor = max(cursor, cut.end)
        }
        if trimEnd > cursor { result.append(cursor...trimEnd) }
        return result.filter { $0.upperBound - $0.lowerBound >= Self.minimumSegment }
    }

    var outputDuration: Double {
        keptRanges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    var isUnedited: Bool { trimStart == 0 && trimEnd == sourceDuration && cuts.isEmpty }

    mutating func setTrimStart(_ t: Double) {
        trimStart = min(max(0, t), trimEnd - Self.minimumSegment)
    }

    mutating func setTrimEnd(_ t: Double) {
        trimEnd = max(min(sourceDuration, t), trimStart + Self.minimumSegment)
    }

    /// Removes `[start, end]` from the output, merging with overlapping cuts.
    mutating func addCut(start: Double, end: Double) {
        var lo = max(0, min(start, end))
        var hi = min(sourceDuration, max(start, end))
        guard hi - lo >= Self.minimumSegment else { return }
        var remaining: [CutRange] = []
        for cut in cuts {
            if cut.end >= lo && cut.start <= hi {
                lo = min(lo, cut.start)
                hi = max(hi, cut.end)
            } else {
                remaining.append(cut)
            }
        }
        remaining.append(CutRange(start: lo, end: hi))
        cuts = remaining.sorted { $0.start < $1.start }
    }

    mutating func removeCut(id: CutRange.ID) {
        cuts.removeAll { $0.id == id }
    }

    mutating func reset() {
        trimStart = 0
        trimEnd = sourceDuration
        cuts = []
    }

    func isRemoved(source t: Double) -> Bool {
        !keptRanges.contains { $0.contains(t) }
    }

    static func sourceTime(forOutput t: Double, kept: [ClosedRange<Double>]) -> Double {
        var acc = 0.0
        for r in kept {
            let len = r.upperBound - r.lowerBound
            if t < acc + len { return r.lowerBound + max(0, t - acc) }
            acc += len
        }
        return kept.last?.upperBound ?? t
    }

    func sourceTime(forOutput t: Double) -> Double {
        Self.sourceTime(forOutput: t, kept: keptRanges)
    }

    /// Output time for a source time. Source times inside removed parts snap to the next kept frame.
    func outputTime(forSource s: Double) -> Double {
        var acc = 0.0
        for r in keptRanges {
            if s < r.lowerBound { return acc }
            if s <= r.upperBound { return acc + (s - r.lowerBound) }
            acc += r.upperBound - r.lowerBound
        }
        return acc
    }
}

extension CMTime {
    init(secondsValue: Double) {
        self = CMTime(seconds: secondsValue, preferredTimescale: 60_000)
    }
}

func formatTimecode(_ seconds: Double, fractional: Bool = true) -> String {
    guard seconds.isFinite else { return "--:--" }
    let s = max(0, seconds)
    let whole = Int(s)
    let h = whole / 3600, m = (whole / 60) % 60, sec = whole % 60
    let hundredths = Int((s - Double(whole)) * 100)
    let base = h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    return fractional ? base + String(format: ".%02d", hundredths) : base
}
