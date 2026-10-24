import CoreGraphics
import CoreMedia
import Foundation

/// One video in the project, with its own trim/cuts and stabilization analysis.
struct Clip: Identifiable {
    let id: UUID
    let source: SourceVideo
    var timeline: EditTimeline
    var thumbnails: [CGImage] = []
    var stabilizationAnalysis: StabilizationAnalysis?

    init(id: UUID = UUID(), source: SourceVideo, timeline: EditTimeline? = nil) {
        self.id = id
        self.source = source
        self.timeline = timeline ?? EditTimeline(sourceDuration: source.duration)
    }

    var name: String { source.url.lastPathComponent }
}

/// What the composition builder needs from a clip.
struct ClipInput: @unchecked Sendable {
    let id: UUID
    let source: SourceVideo
    let timeline: EditTimeline
}

/// A kept part of a clip, placed on the combined output timeline.
struct ClipSegment: Sendable, Equatable {
    let clipID: UUID
    let sourceRange: ClosedRange<Double>
    let outputStart: Double

    var duration: Double { sourceRange.upperBound - sourceRange.lowerBound }
    var outputEnd: Double { outputStart + duration }
}

/// Maps between the combined output timeline and (clip, source time).
enum ProjectTimeline {
    /// The kept parts of every clip, in playback order.
    static func segments(_ clips: [(id: UUID, timeline: EditTimeline)]) -> [ClipSegment] {
        var result: [ClipSegment] = []
        var cursor = 0.0
        for clip in clips {
            for range in clip.timeline.keptRanges {
                let segment = ClipSegment(clipID: clip.id, sourceRange: range, outputStart: cursor)
                result.append(segment)
                cursor = segment.outputEnd
            }
        }
        return result
    }

    /// The clip and source time shown at output time `t` (clamped to the ends).
    static func locate(_ t: Double, in segments: [ClipSegment]) -> (clipID: UUID, sourceTime: Double)? {
        guard let first = segments.first, let last = segments.last else { return nil }
        if t <= first.outputStart { return (first.clipID, first.sourceRange.lowerBound) }
        var lo = 0, hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].outputStart <= t { lo = mid } else { hi = mid - 1 }
        }
        let segment = segments[lo]
        if t >= last.outputEnd { return (last.clipID, last.sourceRange.upperBound) }
        return (segment.clipID, min(segment.sourceRange.lowerBound + (t - segment.outputStart), segment.sourceRange.upperBound))
    }

    /// Output time of `sourceTime` in clip `clipID`; times inside removed parts snap to the clip's next kept frame.
    static func outputTime(clipID: UUID, sourceTime: Double, in segments: [ClipSegment]) -> Double? {
        let clipSegments = segments.filter { $0.clipID == clipID }
        guard let first = clipSegments.first else { return nil }
        for segment in clipSegments {
            if sourceTime < segment.sourceRange.lowerBound { return segment.outputStart }
            if sourceTime <= segment.sourceRange.upperBound {
                return segment.outputStart + (sourceTime - segment.sourceRange.lowerBound)
            }
        }
        return clipSegments.last?.outputEnd ?? first.outputStart
    }

    /// Output size of the combined movie: the first clip's display size. Other clips are fitted inside it.
    static func renderSize(_ clips: [SourceVideo]) -> CGSize {
        clips.first?.displaySize ?? CGSize(width: 1920, height: 1080)
    }

    /// The shortest frame duration (highest frame rate) of all clips, so no clip loses frames.
    static func frameDuration(_ clips: [SourceVideo]) -> CMTime {
        clips.map(\.frameDuration).min { $0.seconds < $1.seconds } ?? CMTime(value: 1, timescale: 30)
    }
}
