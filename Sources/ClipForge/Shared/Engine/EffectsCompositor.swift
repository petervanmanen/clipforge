import AVFoundation
import CoreImage

/// Renders every frame of a single-video-track asset through a Core Image closure.
///
/// This replaces `AVMutableVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)`, whose
/// compositor fails to start playback in the iOS Simulator (AVPlayerItem error -12784) although export works.
/// Owning the compositor also pins the pixel format to BGRA and makes the orientation handling explicit.
enum EffectsComposition {
    typealias Render = @Sendable (_ frame: CIImage, _ time: CMTime) -> CIImage

    /// - Parameters:
    ///   - trackID: the video track in `asset` to render.
    ///   - naturalSize/preferredTransform: of that track; frames are rotated to display orientation before `render`.
    ///   - renderSize: output size; defaults to the display size. `render` must produce an image of this size at the origin.
    static func make(asset: AVAsset, trackID: CMPersistentTrackID, duration: CMTime, naturalSize: CGSize,
                     preferredTransform: CGAffineTransform, frameDuration: CMTime, renderSize: CGSize? = nil,
                     render: @escaping Render) -> AVMutableVideoComposition {
        let orientation = orientationTransform(naturalSize: naturalSize, preferredTransform: preferredTransform)
        let displaySize = CGRect(origin: .zero, size: naturalSize).applying(orientation).size

        let composition = AVMutableVideoComposition()
        composition.customVideoCompositorClass = EffectsCompositor.self
        composition.renderSize = renderSize ?? CGSize(width: displaySize.width.rounded(), height: displaySize.height.rounded())
        composition.frameDuration = frameDuration
        composition.instructions = [EffectsInstruction(
            timeRange: CMTimeRange(start: .zero, duration: duration), trackID: trackID,
            orientation: orientation, render: render)]
        return composition
    }

    /// Maps a frame in Core Image space (origin bottom-left) to display orientation, also with its origin at zero.
    /// `preferredTransform` is defined in a top-left-origin space, so it is wrapped in y-flips.
    static func orientationTransform(naturalSize: CGSize, preferredTransform t: CGAffineTransform) -> CGAffineTransform {
        let displayHeight = abs(CGRect(origin: .zero, size: naturalSize).applying(t).height)
        let toTopLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: naturalSize.height)
        let toBottomLeft = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: displayHeight)
        let combined = toTopLeft.concatenating(t).concatenating(toBottomLeft)
        // Some files carry transforms without the translation part; normalize the origin.
        let rect = CGRect(origin: .zero, size: naturalSize).applying(combined)
        return combined.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }
}

final class EffectsInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let trackID: CMPersistentTrackID
    let orientation: CGAffineTransform
    let render: EffectsComposition.Render

    init(timeRange: CMTimeRange, trackID: CMPersistentTrackID, orientation: CGAffineTransform, render: @escaping EffectsComposition.Render) {
        self.timeRange = timeRange
        self.trackID = trackID
        self.requiredSourceTrackIDs = [NSNumber(value: trackID)]
        self.orientation = orientation
        self.render = render
    }
}

final class EffectsCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private static let bgra: [String: any Sendable] = [
        kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA],
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
    ]

    let sourcePixelBufferAttributes: [String: any Sendable]? = EffectsCompositor.bgra
    let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = EffectsCompositor.bgra

    private let queue = DispatchQueue(label: "ClipForge.EffectsCompositor", qos: .userInitiated)
    // Frames pass through without color management: pixel values are read and written as-is and the output
    // keeps the source's color tags, so an unfiltered frame is bit-for-bit what the decoder produced.
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            autoreleasepool {
                guard let instruction = request.videoCompositionInstruction as? EffectsInstruction,
                      let source = request.sourceFrame(byTrackID: instruction.trackID),
                      let output = request.renderContext.newPixelBuffer()
                else {
                    request.finish(with: NSError(domain: AVFoundationErrorDomain, code: AVError.Code.unknown.rawValue))
                    return
                }
                let frame = CIImage(cvPixelBuffer: source, options: [.colorSpace: NSNull()])
                    .transformed(by: instruction.orientation)
                let image = instruction.render(frame, request.compositionTime)
                let size = request.renderContext.size
                CVBufferPropagateAttachments(source, output)
                context.render(image, to: output, bounds: CGRect(origin: .zero, size: size), colorSpace: nil)
                request.finish(withComposedVideoFrame: output)
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {}
}
