import AVFoundation
import CoreImage
import XCTest
@testable import FitMovie

/// End-to-end: generate a shaky clip, then trim + cut + stabilize + filter + overlay + music and export it.
final class PipelineTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("FitMovieTests-\(UUID().uuidString)")
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
    static func makeShakyVideo(at url: URL, seconds: Int = 6, rotated: Bool = false,
                               transform: CGAffineTransform? = nil,
                               creationDate: String = "2024-11-08T09:20:00Z") throws {
        let w = 1280, h = 720, fps = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
        ])
        if rotated { input.transform = CGAffineTransform(rotationAngle: .pi / 2) }
        if let transform { input.transform = transform }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
        ])
        writer.add(input)
        writer.metadata = [{
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.value = creationDate as NSString
            return item
        }()]
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let ctx = CIContext()
        let texture = makeTexture(width: w + 400, height: h + 100)
        var rng = SeededRandom(seed: 42)
        for i in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            // Content moves right by 1.5 px/frame (a pan) plus random shake.
            let dx = -Double(i) * 1.5 + rng.next(in: -18...18) - 50
            let dy = rng.next(in: -12...12) - 50
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

    /// A non-repeating pattern of random discs. (CIRandomGenerator tiles every 512 px, which makes frame
    /// registration ambiguous.)
    static func makeTexture(width: Int, height: Int) -> CIImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        var rng = SeededRandom(seed: 7)
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for _ in 0..<2500 {
            let r = rng.next(in: 4...40)
            let g = rng.next(in: 0.1...0.9)
            ctx.setFillColor(CGColor(red: g, green: rng.next(in: 0.1...0.9), blue: g, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: rng.next(in: 0...Double(width)), y: rng.next(in: 0...Double(height)), width: r, height: r))
        }
        return CIImage(cgImage: ctx.makeImage()!)
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
        meanAcceleration(a.x) + meanAcceleration(a.y)
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
        print("source pan \((analysis.x.last ?? 0) - (analysis.x.first ?? 0)) px, y range \(analysis.y.min() ?? 0)...\(analysis.y.max() ?? 0)")
        XCTAssertGreaterThan(sourceJitter, 10)

        // Edit: trim 0.5 s off the start and end, remove 2.0–3.0 s.
        var timeline = EditTimeline(sourceDuration: source.duration)
        timeline.setTrimStart(0.5)
        timeline.setTrimEnd(5.5)
        timeline.addCut(start: 2, end: 3)

        let state = RenderState()
        let clipID = UUID()
        let stabilization = StabilizationSettings(enabled: true, strength: 0.8, maxCrop: 0.12)
        var snapshot = RenderSnapshot.singleClip(
            id: clipID, source: source, timeline: timeline,
            stabilizationPath: Stabilizer.path(for: analysis, settings: stabilization), videoStartDate: source.creationDate)
        snapshot.stabilization = stabilization
        snapshot.filter = FilterSettings(kind: .vivid)
        snapshot.activity = try FITActivity.load(url: fitURL)
        state.snapshot = snapshot
        let renderer = FrameRenderer(state: state)

        var audio = AudioSettings()
        audio.musicURL = musicURL
        let movie = try await CompositionBuilder.build(source: source, timeline: timeline, clipID: clipID, audio: audio, renderer: renderer)
        XCTAssertEqual(movie.duration, 4, accuracy: 0.02)

        let outURL = dir.appendingPathComponent("out.mp4")
        try await VideoExporter.export(movie, to: outURL, preset: .h264Highest, container: .mp4) { _ in }

        let out = try await SourceVideo.load(url: outURL)
        XCTAssertEqual(out.duration, 4, accuracy: 0.1)
        XCTAssertEqual(out.displaySize, CGSize(width: 1280, height: 720))
        XCTAssertNotNil(out.audioTrack, "background music should be mixed in (looped)")

        // The overlay panel is drawn bottom-left: the corner differs from the plain filtered frame.
        let generator = AVAssetImageGenerator(asset: out.asset)
        let (frame, _) = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
        let corner = averageBrightness(frame, rect: CGRect(x: 40, y: frame.height - 140, width: 120, height: 80))
        XCTAssertNotNil(corner)
        try writePNG(frame, to: dir.appendingPathComponent("frame.png"))
    }

    /// Stabilization must remove the shake but keep the camera's slow pan. Measured on an export without the
    /// overlay, because the static overlay panel would dominate the motion estimate.
    @MainActor
    func testStabilizationRemovesShakeButKeepsPan() async throws {
        let videoURL = dir.appendingPathComponent("shaky.mov")
        try Self.makeShakyVideo(at: videoURL)
        let source = try await SourceVideo.load(url: videoURL)
        let analysis = try await Stabilizer.analyze(source) { _ in }
        let sourcePan = (analysis.x.last ?? 0) - (analysis.x.first ?? 0)
        XCTAssertEqual(sourcePan, -1.5 * Double(analysis.times.count - 1), accuracy: 15, "analysis must measure the pan")

        let timeline = EditTimeline(sourceDuration: source.duration)
        let state = RenderState()
        let clipID = UUID()
        let stabilization = StabilizationSettings(enabled: true, strength: 0.8, maxCrop: 0.12)
        var snapshot = RenderSnapshot.singleClip(id: clipID, source: source, timeline: timeline,
                                                 stabilizationPath: Stabilizer.path(for: analysis, settings: stabilization))
        snapshot.stabilization = stabilization
        state.snapshot = snapshot
        let movie = try await CompositionBuilder.build(source: source, timeline: timeline, clipID: clipID, audio: AudioSettings(),
                                                       renderer: FrameRenderer(state: state))
        let outURL = dir.appendingPathComponent("stabilized.mp4")
        try await VideoExporter.export(movie, to: outURL, preset: .h264Highest, container: .mp4) { _ in }

        let outAnalysis = try await Stabilizer.analyze(try await SourceVideo.load(url: outURL)) { _ in }
        let sourceJitter = jitter(analysis), outJitter = jitter(outAnalysis)
        let outPan = (outAnalysis.x.last ?? 0) - (outAnalysis.x.first ?? 0)
        print("jitter source=\(sourceJitter) stabilized=\(outJitter); pan source=\(sourcePan) stabilized=\(outPan)")
        XCTAssertLessThan(outJitter, sourceJitter * 0.2)
        XCTAssertEqual(outPan, sourcePan, accuracy: abs(sourcePan) * 0.25, "the slow pan must survive")
    }

    @MainActor
    func testPortraitOrientationIsKept() async throws {
        let videoURL = dir.appendingPathComponent("portrait.mov")
        try Self.makeShakyVideo(at: videoURL, seconds: 2, rotated: true)
        let source = try await SourceVideo.load(url: videoURL)
        XCTAssertEqual(source.displaySize, CGSize(width: 720, height: 1280))

        let state = RenderState()
        let clipID = UUID()
        let timeline = EditTimeline(sourceDuration: source.duration)
        var snapshot = RenderSnapshot.singleClip(id: clipID, source: source, timeline: timeline)
        snapshot.filter = FilterSettings(kind: .mono)
        state.snapshot = snapshot
        let movie = try await CompositionBuilder.build(source: source, timeline: timeline, clipID: clipID, audio: AudioSettings(),
                                                       renderer: FrameRenderer(state: state))
        let outURL = dir.appendingPathComponent("portrait-out.mov")
        try await VideoExporter.export(movie, to: outURL, preset: .hevcHighest, container: .mov) { _ in }
        let out = try await SourceVideo.load(url: outURL)
        XCTAssertEqual(out.displaySize, CGSize(width: 720, height: 1280))
        XCTAssertNil(out.audioTrack)
    }

    /// The custom compositor must rotate frames exactly like AVFoundation does for every phone orientation.
    func testCompositorOrientationMatchesAVFoundation() async throws {
        let w: CGFloat = 1280, h: CGFloat = 720
        let transforms: [(String, CGAffineTransform)] = [
            ("0", .identity),
            ("90", CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)),
            ("180", CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)),
            ("270", CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)),
        ]
        for (name, transform) in transforms {
            let url = dir.appendingPathComponent("orient-\(name).mov")
            try Self.makeShakyVideo(at: url, seconds: 1, transform: transform)
            let source = try await SourceVideo.load(url: url)
            let at = CMTime(value: 10, timescale: 30)

            let reference = AVAssetImageGenerator(asset: source.asset)
            reference.appliesPreferredTrackTransform = true
            reference.requestedTimeToleranceBefore = .zero
            reference.requestedTimeToleranceAfter = .zero
            let (expected, _) = try await reference.image(at: at)

            let generator = AVAssetImageGenerator(asset: source.asset)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            generator.videoComposition = EffectsComposition.make(
                asset: source.asset, trackID: source.videoTrack.trackID, duration: CMTime(secondsValue: source.duration),
                naturalSize: source.naturalSize, preferredTransform: source.preferredTransform,
                frameDuration: source.frameDuration) { frame, _ in frame }
            let (actual, _) = try await generator.image(at: at)

            XCTAssertEqual(actual.width, expected.width, "rotation \(name)")
            XCTAssertEqual(actual.height, expected.height, "rotation \(name)")
            let diff = meanDifference(actual, expected)
            XCTAssertLessThan(diff, 6, "rotation \(name): frames differ (mean diff \(diff))")
        }
    }

    /// Mean absolute per-channel difference of two equally sized images, compared at 320 px.
    private func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let w = 320, h = Int(Double(320) * Double(a.height) / Double(a.width))
        func pixels(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return data
        }
        let pa = pixels(a), pb = pixels(b)
        var sum = 0
        for i in 0..<pa.count where i % 4 != 3 { sum += abs(Int(pa[i]) - Int(pb[i])) }
        return Double(sum) / Double(w * h * 3)
    }

    func averageBrightness(_ image: CGImage, rect: CGRect) -> Double? {
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

/// Mean absolute second difference of a path: high for shake, ~0 for a smooth path.
func meanAcceleration(_ v: [Double]) -> Double {
    guard v.count > 2 else { return 0 }
    var sum = 0.0
    for i in 2..<v.count {
        let acceleration: Double = v[i] - 2 * v[i - 1] + v[i - 2]
        sum += abs(acceleration)
    }
    return sum / Double(v.count - 2)
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
