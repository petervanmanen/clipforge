import CoreImage
import Foundation

/// Everything the per-frame renderer needs, captured as an immutable value.
struct RenderSnapshot: Sendable {
    var keptRanges: [ClosedRange<Double>] = []
    var sourceDuration: Double = 0
    var filter = FilterSettings()
    var stabilization = StabilizationSettings()
    var stabilizationPath: StabilizationPath?
    var overlay = OverlaySettings()
    var activity: FITActivity?
    /// Video recording start on the watch's (UTC) clock, before the user's fine offset.
    var videoStartDate: Date?
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

    /// Renders a frame of the edited output (time on the edited timeline).
    func render(_ image: CIImage, outputTime: Double) -> CIImage {
        let snapshot = state.snapshot
        let sourceTime = EditTimeline.sourceTime(forOutput: outputTime, kept: snapshot.keptRanges)
        return render(image, sourceTime: sourceTime, snapshot: snapshot)
    }

    /// Renders a frame of the unedited source (used for scrub previews).
    func render(_ image: CIImage, sourceTime: Double) -> CIImage {
        render(image, sourceTime: sourceTime, snapshot: state.snapshot)
    }

    func render(_ input: CIImage, sourceTime: Double, snapshot: RenderSnapshot) -> CIImage {
        let extent = input.extent
        var image = input

        if snapshot.stabilization.enabled, let path = snapshot.stabilizationPath {
            image = Stabilizer.apply(path, to: image, at: sourceTime)
        }

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

        if let overlay = overlayRenderer.overlay(for: snapshot, sourceTime: sourceTime, frame: extent) {
            image = overlay.composited(over: image)
        }
        return image.cropped(to: extent)
    }
}
