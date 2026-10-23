import AVFoundation
import CoreImage
import Vision

/// The measured camera path of a clip: cumulative frame-to-frame translation, in display pixels.
struct StabilizationAnalysis: Sendable {
    var times: [Double]
    var x: [Double]
    var y: [Double]
    var frameSize: CGSize
    var frameRate: Double
}

/// Per-frame corrective translation (display pixels) for a given strength/crop.
struct StabilizationPath: Sendable {
    var times: [Double]
    var dx: [Double]
    var dy: [Double]
    var maxCrop: Double

    func correction(at t: Double) -> CGVector {
        guard !times.isEmpty else { return .zero }
        var lo = 0, hi = times.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if times[mid] <= t + 0.001 { lo = mid } else { hi = mid - 1 }
        }
        return CGVector(dx: dx[lo], dy: dy[lo])
    }
}

enum Stabilizer {
    /// Long side of the frames used for motion estimation.
    private static let analysisDimension: CGFloat = 640

    /// Measures the camera motion of the whole source clip with Vision image registration.
    static func analyze(_ source: SourceVideo, progress: @escaping @Sendable (Double) -> Void) async throws -> StabilizationAnalysis {
        let size = source.displaySize
        let scale = min(1, analysisDimension / max(size.width, size.height))
        let analysisSize = CGSize(width: (size.width * scale / 2).rounded() * 2, height: (size.height * scale / 2).rounded() * 2)

        // The same compositor as playback/export gives identically oriented, downscaled frames.
        let composition = EffectsComposition.make(
            asset: source.asset, trackID: source.videoTrack.trackID, duration: CMTime(secondsValue: source.duration),
            naturalSize: source.naturalSize, preferredTransform: source.preferredTransform,
            frameDuration: source.frameDuration, renderSize: analysisSize
        ) { frame, _ in
            // Lanczos downscaling avoids aliasing, which would otherwise show up as false motion.
            let scaleY = analysisSize.height / frame.extent.height
            let aspect = (analysisSize.width / frame.extent.width) / scaleY
            return frame.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: aspect,
            ])
        }

        let reader = try AVAssetReader(asset: source.asset)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: [source.videoTrack],
            videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.videoComposition = composition
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var times: [Double] = []
        var xs: [Double] = []
        var ys: [Double] = []
        var x = 0.0, y = 0.0
        var previous: CIImage?
        let maxJump = Double(analysisSize.width) * 0.25
        let sequenceHandler = VNSequenceRequestHandler()

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let image = CIImage(cvPixelBuffer: buffer)

            if let previous {
                // Reference = previous frame, floating = current frame. The returned transform maps the current
                // frame back onto the previous one, so the content moved by its negation.
                let request = VNTranslationalImageRegistrationRequest(targetedCIImage: image)
                if (try? sequenceHandler.perform([request], on: previous)) != nil,
                   let observation = request.results?.first as? VNImageTranslationAlignmentObservation {
                    let mx = -Double(observation.alignmentTransform.tx)
                    let my = -Double(observation.alignmentTransform.ty)
                    if abs(mx) < maxJump && abs(my) < maxJump { // ignore scene cuts / failures
                        x += mx / Double(scale)
                        y += my / Double(scale)
                    }
                }
            }
            // Keep a copy: the reader may recycle the pixel buffer.
            previous = image.copyToMemory()
            times.append(t)
            xs.append(x)
            ys.append(y)
            if times.count % 10 == 0 { progress(min(1, t / max(source.duration, 0.01))) }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        progress(1)
        return StabilizationAnalysis(times: times, x: xs, y: ys, frameSize: size, frameRate: source.frameRate)
    }

    /// Smooths the measured camera path and returns the correction needed to follow the smooth path,
    /// limited so the frame edges stay hidden inside the allowed crop.
    static func path(for analysis: StabilizationAnalysis, settings: StabilizationSettings) -> StabilizationPath {
        let radius = max(1, Int(settings.strength * analysis.frameRate * 2))
        let marginX = Double(analysis.frameSize.width) * settings.maxCrop / 2
        let marginY = Double(analysis.frameSize.height) * settings.maxCrop / 2

        func solve(_ trajectory: [Double], margin: Double) -> [Double] {
            var smooth = boxSmooth(boxSmooth(trajectory, radius: radius), radius: radius)
            // Pull the smooth path back toward the real one wherever the correction would exceed the crop,
            // then re-smooth so the pull doesn't introduce sudden jumps.
            for _ in 0..<4 {
                for i in smooth.indices {
                    smooth[i] = trajectory[i] + min(max(smooth[i] - trajectory[i], -margin), margin)
                }
                smooth = boxSmooth(smooth, radius: max(1, radius / 4))
            }
            return smooth.indices.map { min(max(smooth[$0] - trajectory[$0], -margin), margin) }
        }

        return StabilizationPath(
            times: analysis.times,
            dx: solve(analysis.x, margin: marginX),
            dy: solve(analysis.y, margin: marginY),
            maxCrop: settings.maxCrop)
    }

    /// Centered moving average, O(n). The ends are extended by point reflection (x0 - (x[k] - x0)), so a steady
    /// pan stays a straight line instead of flattening out at the start and end of the clip.
    static func boxSmooth(_ v: [Double], radius: Int) -> [Double] {
        guard v.count > 1, radius > 0 else { return v }
        let n = v.count
        let pad = min(radius, n - 1)
        let head = (1...pad).reversed().map { 2 * v[0] - v[$0] }
        let tail = (1...pad).map { 2 * v[n - 1] - v[n - 1 - $0] }
        let padded = head + v + tail
        var prefix = [0.0]
        prefix.reserveCapacity(padded.count + 1)
        for value in padded { prefix.append(prefix.last! + value) }
        return (0..<n).map { j in
            let i = j + pad
            let lo = max(0, i - radius), hi = min(padded.count - 1, i + radius)
            return (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
        }
    }

    /// Applies the correction for `t`, then zooms in just enough to hide the shifted edges.
    static func apply(_ path: StabilizationPath, to image: CIImage, at t: Double) -> CIImage {
        let extent = image.extent
        let crop = min(max(path.maxCrop, 0), 0.5)
        guard crop > 0 else { return image }
        var d = path.correction(at: t)
        d.dx = min(max(d.dx, -extent.width * crop / 2), extent.width * crop / 2)
        d.dy = min(max(d.dy, -extent.height * crop / 2), extent.height * crop / 2)
        let zoom = 1 / (1 - crop)
        let cx = extent.midX, cy = extent.midY
        let transform = CGAffineTransform(translationX: d.dx, y: d.dy)
            .concatenating(CGAffineTransform(translationX: -cx, y: -cy))
            .concatenating(CGAffineTransform(scaleX: zoom, y: zoom))
            .concatenating(CGAffineTransform(translationX: cx, y: cy))
        return image.clampedToExtent().transformed(by: transform).cropped(to: extent)
    }
}

private extension CIImage {
    static let copyContext = CIContext(options: [.cacheIntermediates: false])

    func copyToMemory() -> CIImage {
        guard let cg = CIImage.copyContext.createCGImage(self, from: extent) else { return self }
        return CIImage(cgImage: cg)
    }
}
