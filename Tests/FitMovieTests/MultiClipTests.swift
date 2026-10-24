import AVFoundation
import XCTest
@testable import FitMovie

final class ProjectTimelineTests: XCTestCase {
    func testSegmentsAndMapping() {
        let a = UUID(), b = UUID()
        var first = EditTimeline(sourceDuration: 10)
        first.setTrimStart(2)                 // keeps 2–10 minus the cut
        first.addCut(start: 4, end: 6)        // kept: 2–4, 6–10 → 6 s
        var second = EditTimeline(sourceDuration: 5)
        second.setTrimEnd(3)                  // kept: 0–3 → 3 s
        let segments = ProjectTimeline.segments([(a, first), (b, second)])

        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.last?.outputEnd ?? 0, 9, accuracy: 1e-9)

        // Output → (clip, source)
        XCTAssertEqual(ProjectTimeline.locate(0, in: segments)?.clipID, a)
        XCTAssertEqual(ProjectTimeline.locate(0, in: segments)?.sourceTime ?? -1, 2, accuracy: 1e-9)
        XCTAssertEqual(ProjectTimeline.locate(3, in: segments)?.sourceTime ?? -1, 7, accuracy: 1e-9)  // after the cut
        XCTAssertEqual(ProjectTimeline.locate(7, in: segments)?.clipID, b)
        XCTAssertEqual(ProjectTimeline.locate(7, in: segments)?.sourceTime ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(ProjectTimeline.locate(100, in: segments)?.sourceTime ?? -1, 3, accuracy: 1e-9)  // clamped

        // (clip, source) → output
        XCTAssertEqual(ProjectTimeline.outputTime(clipID: b, sourceTime: 1, in: segments) ?? -1, 7, accuracy: 1e-9)
        XCTAssertEqual(ProjectTimeline.outputTime(clipID: a, sourceTime: 5, in: segments) ?? -1, 2, accuracy: 1e-9)  // in cut
        XCTAssertNil(ProjectTimeline.outputTime(clipID: UUID(), sourceTime: 0, in: segments))
    }

    func testFitLetterboxesOtherShapes() {
        let portrait = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 720, height: 1280))
        let fitted = FrameRenderer.fit(portrait, into: CGSize(width: 1280, height: 720))
        XCTAssertEqual(fitted.extent, CGRect(x: 0, y: 0, width: 1280, height: 720))
    }
}

/// End to end: two clips of different orientation and recording time combined into one movie.
final class MultiClipPipelineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FitMovieMultiClip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor
    func testCombinesClipsInOneMovie() async throws {
        let landscapeURL = dir.appendingPathComponent("GX010001.MP4.mov")
        let portraitURL = dir.appendingPathComponent("IMG_0002.mov")
        try PipelineTests.makeShakyVideo(at: landscapeURL, seconds: 3, creationDate: "2024-11-08T09:20:00Z")
        try PipelineTests.makeShakyVideo(at: portraitURL, seconds: 2, rotated: true, creationDate: "2024-11-08T09:25:00Z")

        let model = EditorModel()
        await model.addVideos([landscapeURL, portraitURL], replacingProject: true)
        XCTAssertEqual(model.clips.count, 2)
        XCTAssertEqual(model.selectedClipID, model.clips[0].id)
        XCTAssertEqual(model.renderSize, CGSize(width: 1280, height: 720), "the first clip sets the frame size")

        // Trim the first clip to 0.5–2.5 s through the selected-clip API.
        model.timeline.setTrimStart(0.5)
        model.timeline.setTrimEnd(2.5)
        XCTAssertEqual(model.outputDuration, 4, accuracy: 0.05)
        XCTAssertEqual(model.clips[1].timeline.trimStart, 0, "editing one clip leaves the others alone")

        // Each clip keeps its own recording time for the overlay (GoPro-style local clock is off here).
        model.videoClockIsLocal = false
        let starts = model.videoStartDates
        let gap = try XCTUnwrap(starts[model.clips[1].id]).timeIntervalSince(try XCTUnwrap(starts[model.clips[0].id]))
        XCTAssertEqual(gap, 300, accuracy: 0.5)
        XCTAssertEqual(model.renderState.snapshot.clips.count, 2)
        XCTAssertNotNil(model.renderState.snapshot.overlayWindow)

        // Reordering puts the portrait clip first, which then sets the frame size.
        model.moveClip(model.clips[1].id, by: -1)
        XCTAssertEqual(model.clips[0].source.url, portraitURL)
        XCTAssertEqual(model.renderSize, CGSize(width: 720, height: 1280))
        model.moveClip(model.clips[0].id, by: 1)

        // Export the combined movie.
        let inputs = model.clips.map { ClipInput(id: $0.id, source: $0.source, timeline: $0.timeline) }
        let movie = try await CompositionBuilder.build(clips: inputs, audio: AudioSettings(), renderer: model.renderer,
                                                       renderSize: model.renderSize)
        XCTAssertEqual(movie.duration, 4, accuracy: 0.05)
        let outURL = dir.appendingPathComponent("combined.mp4")
        try await VideoExporter.export(movie, to: outURL, preset: .h264Highest, container: .mp4) { _ in }
        let out = try await SourceVideo.load(url: outURL)
        XCTAssertEqual(out.duration, 4, accuracy: 0.1)
        XCTAssertEqual(out.displaySize, CGSize(width: 1280, height: 720))

        // In the landscape part the frame is filled; in the portrait part the sides are black bars.
        let generator = AVAssetImageGenerator(asset: out.asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (landscapeFrame, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let (portraitFrame, _) = try await generator.image(at: CMTime(seconds: 3, preferredTimescale: 600))
        let leftEdge = CGRect(x: 10, y: 300, width: 60, height: 120)
        let center = CGRect(x: 600, y: 300, width: 80, height: 120)
        XCTAssertGreaterThan(brightness(landscapeFrame, leftEdge), 40)
        XCTAssertLessThan(brightness(portraitFrame, leftEdge), 8, "portrait clip must be letterboxed")
        XCTAssertGreaterThan(brightness(portraitFrame, center), 40)

        // Removing a clip shortens the movie.
        model.removeClip(model.clips[1].id)
        XCTAssertEqual(model.clips.count, 1)
        XCTAssertEqual(model.outputDuration, 2, accuracy: 0.05)
    }

    private func brightness(_ image: CGImage, _ rect: CGRect) -> Double {
        guard let cropped = image.cropping(to: rect),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return -1 }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(p[0]) + Double(p[1]) + Double(p[2])) / 3
    }
}
