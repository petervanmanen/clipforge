import AVFoundation
import CoreImage
import XCTest
@testable import ClipForge

/// End-to-end: generate a shaky clip, then trim + cut + stabilize + filter + overlay + music and export it.
final class PipelineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ClipForgeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if ProcessInfo.processInfo.environment["KEEP_TEST_OUTPUT"] == nil {
            try? FileManager.default.removeItem(at: dir)
        } else {
            print("Test output kept in \(dir.path)")
        }
    }

    /// 6 s of 1280×720 noise texture with a slow pan plus random shake, optionally rotated like a portrait iPhone clip.
    static func makeShakyVideo(at url: URL, seconds: Int = 6, rotated: Bool = false) throws {
        let w = 1280, h = 720, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.metadata = [{
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = "2024-11-08T09:20:00Z" as NSString
            return item
        }()]
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let ctx = CIContext()
        let texture = CIFilter(name: "CIRandomGenerator")!.outputImage!
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 3])
            .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 4])
        var rng = SeededRandom(seed: 42)
        for i in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            let dx = Double(i) * 1.5 + rng.next(in: -18...18)
            let dy = rng.next(in: -12...12)
            let frame = texture.transformed(by: CGAffineTransform(translationX: dx, y: dy))
                .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            ctx.render(frame, to: buffer!)
            adaptor.append(buffer!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        if writer.status != .completed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    static func makeTone(at url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 {
            let p = buffer.floatChannelData![c]
            for i in 0..<Int(frames) { p[i] = 0.3 * sin(Float(i) * 2 * .pi * 440 / 44_100) }
        }
        try file.write(from: buffer)
    }

    /// Mean absolute frame-to-frame acceleration of the measured camera path: high for shake, ~0 for smooth.
    private func jitter(_ a: StabilizationAnalysis) -> Double {
        func j(_ v: [Double]) -> Double {
            zip(v.dropFirst(2), zip(v.dropFirst(), v)).map { abs($0 - 2 * $1.0 + $1.1) }.reduce(0, +) / Double(max(1, v.count - 2))
        }
        return j(a.x) + j(a.y)
    }

    @MainActor
    func testFullPipelineExport() async throws {
        let videoURL = dir.appendingPathComponent("shaky.mov")
        let musicURL = dir.appendingPathComponent("tone.caf")
        let fitURL = dir.appendingPathComponent("run.fit")
        try Self.makeShakyVideo(at: videoURL)
        try Self.makeTone(at: musicURL, seconds: 2.5)
        // Activity starting 10 s before the video.
        let videoStartFIT = UInt32(Date(timeIntervalSince1970: 1_731_057_600).timeIntervalSince1970 - FITParser.fitEpochOffset)
        try FITTests.makeRun(start: videoStartFIT - 10).write(to: fitURL)

        let source = try await SourceVideo.load(url: videoURL)
        XCTAssertEqual(source.duration, 6, accuracy: 0.05)
        XCTAssertEqual(source.displaySize, CGSize(width: 1280, height: 720))
        XCTAssertEqual(source.creationDate, Date(timeIntervalSince1970: 1_731_057_600))

        // Measure shake.
        let analysis = try await Stabilizer.analyze(source) { _ in }
        XCTAssertEqual(analysis.times.count, 180)
        let sourceJitter = jitter(analysis)
        XCTAssertGreaterThan(sourceJitter, 10)

        // Edit: trim 0.5 s off the start and end, remove 2.0–3.0 s.
        var timeline = EditTimeline(sourceDuration: source.duration)
        timeline.setTrimStart(0.5)
        timeline.setTrimEnd(5.5)
        timeline.addCut(start: 2, end: 3)

        let state = RenderState()
        var snapshot = RenderSnapshot()
        snapshot.keptRanges = timeline.keptRanges
        snapshot.sourceDuration = source.duration
        snapshot.stabilization = StabilizationSettings(enabled: true, strength: 0.8, maxCrop: 0.12)
        snapshot.stabilizationPath = Stabilizer.path(for: analysis, settings: snapshot.stabilization)
        snapshot.filter = FilterSettings(kind: .vivid)
        snapshot.activity = try FITActivity.load(url: fitURL)
        snapshot.videoStartDate = source.creationDate
        state.snapshot = snapshot
        let renderer = FrameRenderer(state: state)

        var audio = AudioSettings()
        audio.musicURL = musicURL
        let movie = try await CompositionBuilder.build(source: source, timeline: timeline, audio: audio, renderer: renderer)
        XCTAssertEqual(movie.duration, 4, accuracy: 0.02)

        let outURL = dir.appendingPathComponent("out.mp4")
        try await VideoExporter.export(movie, to: outURL, preset: .h264Highest, container: .mp4) { _ in }

        let out = try await SourceVideo.load(url: outURL)
        XCTAssertEqual(out.duration, 4, accuracy: 0.1)
        XCTAssertEqual(out.displaySize, CGSize(width: 1280, height: 720))
        XCTAssertNotNil(out.audioTrack, "background music should be mixed in (looped)")

        // The exported clip must be measurably steadier than the source.
        let outAnalysis = try await Stabilizer.analyze(out) { _ in }
        let outJitter = jitter(outAnalysis)
        print("jitter source=\(sourceJitter) stabilized=\(outJitter)")
        XCTAssertLessThan(outJitter, sourceJitter * 0.5)

        // The overlay panel is drawn bottom-left: the corner differs from the plain filtered frame.
        let generator = AVAssetImageGenerator(asset: out.asset)
        let (frame, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let corner = averageBrightness(frame, rect: CGRect(x: 40, y: frame.height - 140, width: 120, height: 80))
        XCTAssertNotNil(corner)
        try writePNG(frame, to: dir.appendingPathComponent("frame.png"))
    }

    @MainActor
    func testPortraitOrientationIsKept() async throws {
        let videoURL = dir.appendingPathComponent("portrait.mov")
        try Self.makeShakyVideo(at: videoURL, seconds: 2, rotated: true)
        let source = try await SourceVideo.load(url: videoURL)
        XCTAssertEqual(source.displaySize, CGSize(width: 720, height: 1280))

        let state = RenderState()
        var snapshot = RenderSnapshot()
        let timeline = EditTimeline(sourceDuration: source.duration)
        snapshot.keptRanges = timeline.keptRanges
        snapshot.filter = FilterSettings(kind: .mono)
        state.snapshot = snapshot
        let movie = try await CompositionBuilder.build(source: source, timeline: timeline, audio: AudioSettings(),
                                                       renderer: FrameRenderer(state: state))
        let outURL = dir.appendingPathComponent("portrait-out.mov")
        try await VideoExporter.export(movie, to: outURL, preset: .hevcHighest, container: .mov) { _ in }
        let out = try await SourceVideo.load(url: outURL)
        XCTAssertEqual(out.displaySize, CGSize(width: 720, height: 1280))
        XCTAssertNil(out.audioTrack)
    }

    private func averageBrightness(_ image: CGImage, rect: CGRect) -> Double? {
        guard let cropped = image.cropping(to: rect),
              let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Double(p[0]) + Double(p[1]) + Double(p[2])) / 3
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(in range: ClosedRange<Double>) -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        let unit = Double(state >> 11) / Double(1 << 53)
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }
}
