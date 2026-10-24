import CoreImage
import Foundation

/// Everything the per-frame renderer needs, captured as an immutable value.
struct RenderSnapshot: Sendable {
    /// Per-clip data the renderer needs.
    struct ClipInfo: Sendable {
        var stabilizationPath: StabilizationPath?
        /// Recording start on the watch's (UTC) clock, before the user's fine offset.
        var videoStartDate: Date?
    }

    /// The combined output timeline: kept parts of every clip, in order.
    var segments: [ClipSegment] = []
    var clips: [UUID: ClipInfo] = [:]
    /// Output frame size; frames of other sizes are fitted inside it.
    var renderSize: CGSize = .zero
    /// The span of all clips on the video clock (before the fine offset); the overlay graph covers it.
    var overlayWindow: ClosedRange<Date>?
    var filter = FilterSettings()
    var stabilization = StabilizationSettings()
    var overlay = OverlaySettings()
    var activity: FITActivity?

    /// A snapshot for one clip played whole or trimmed (used by tests and single-clip tools).
    static func singleClip(id: UUID, source: SourceVideo, timeline: EditTimeline,
                           stabilizationPath: StabilizationPath? = nil, videoStartDate: Date? = nil) -> RenderSnapshot {
        var snapshot = RenderSnapshot()
        snapshot.segments = ProjectTimeline.segments([(id, timeline)])
        snapshot.clips = [id: ClipInfo(stabilizationPath: stabilizationPath, videoStartDate: videoStartDate)]
        snapshot.renderSize = source.displaySize
        if let start = videoStartDate { snapshot.overlayWindow = start...start.addingTimeInterval(source.duration) }
        return snapshot
    }
}

/// Thread-safe holder for the current snapshot; the video compositor reads it on its own threads.
final class RenderState: @unchecked Sendable {
    private let lock = NSLock()
    private var _snapshot = RenderSnapshot()

    var snapshot: RenderSnapshot {
        get { lock.lock(); defer { lock.unlock() }; return _snapshot }
        set { lock.lock(); _snapshot = newValue; lock.unlock() }
    }
}

/// Applies stabilization, filters and the data overlay to one video frame.
final class FrameRenderer: @unchecked Sendable {
    let state: RenderState
    private let overlayRenderer = OverlayRenderer()

    init(state: RenderState) {
        self.state = state
    }

    /// Renders a frame of the edited output (time on the combined timeline).
    func render(_ image: CIImage, outputTime: Double) -> CIImage {
        let snapshot = state.snapshot
        guard let (clipID, sourceTime) = ProjectTimeline.locate(outputTime, in: snapshot.segments) else { return image }
        return render(image, clipID: clipID, sourceTime: sourceTime, snapshot: snapshot)
    }

    /// Renders any frame of one clip's unedited source (used for scrub previews).
    func render(_ image: CIImage, clipID: UUID, sourceTime: Double) -> CIImage {
        render(image, clipID: clipID, sourceTime: sourceTime, snapshot: state.snapshot)
    }

    func render(_ input: CIImage, clipID: UUID, sourceTime: Double, snapshot: RenderSnapshot) -> CIImage {
        let clip = snapshot.clips[clipID]
        var image = input

        // Stabilize in the clip's own pixels, then fit the clip into the project's frame size.
        if snapshot.stabilization.enabled, let path = clip?.stabilizationPath {
            image = Stabilizer.apply(path, to: image, at: sourceTime)
        }
        image = Self.fit(image, into: snapshot.renderSize)
        let extent = image.extent

        let f = snapshot.filter
        if !f.isIdentity {
            if f.kind != .none && f.intensity > 0 {
                let filtered = f.kind.apply(to: image)
                image = f.intensity >= 1 ? filtered : filtered.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: image, kCIInputTimeKey: 1 - f.intensity,
                ])
            }
            if f.brightness != 0 || f.contrast != 1 || f.saturation != 1 {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: f.brightness, kCIInputContrastKey: f.contrast, kCIInputSaturationKey: f.saturation,
                ])
            }
            if f.vignette > 0 {
                image = image.applyingFilter("CIVignetteEffect", parameters: [
                    kCIInputCenterKey: CIVector(x: extent.midX, y: extent.midY),
                    kCIInputRadiusKey: hypot(extent.width, extent.height) * 0.42,
                    kCIInputIntensityKey: f.vignette,
                    "inputFalloff": 0.6,
                ])
            }
            image = image.cropped(to: extent)
        }

        let videoClock = clip?.videoStartDate?.addingTimeInterval(sourceTime)
        if let videoClock, let overlay = overlayRenderer.overlay(for: snapshot, videoClock: videoClock, frame: extent) {
            image = overlay.composited(over: image)
        }
        return image.cropped(to: extent)
    }

    /// Scales `image` to fit `size` (keeping its aspect ratio) and centers it on black.
    static func fit(_ image: CIImage, into size: CGSize) -> CIImage {
        let extent = image.extent
        guard size.width > 0, size.height > 0, extent.width > 0, extent.height > 0,
              abs(extent.width - size.width) > 0.5 || abs(extent.height - size.height) > 0.5 || extent.origin != .zero
        else { return image }
        let scale = min(size.width / extent.width, size.height / extent.height)
        let w = extent.width * scale, h = extent.height * scale
        let placed = image
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded()))
        let frame = CGRect(origin: .zero, size: size)
        return placed.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: frame)).cropped(to: frame)
    }
}
