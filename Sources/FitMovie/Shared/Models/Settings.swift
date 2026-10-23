import Foundation
import CoreImage

enum FilterKind: String, CaseIterable, Identifiable, Sendable {
    case none, vivid, mono, noir, sepia, chrome, fade, instant, warm, cool, underwater

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Extra Vivid"
        case .mono: return "Black & White"
        case .noir: return "Noir"
        case .sepia: return "Sepia"
        case .chrome: return "Chrome"
        case .fade: return "Fade"
        case .instant: return "Instant"
        case .warm: return "Warm"
        case .cool: return "Cool"
        case .underwater: return "Underwater Fix"
        }
    }

    func apply(to image: CIImage) -> CIImage {
        switch self {
        case .none:
            return image
        case .vivid:
            return image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.9])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.3, kCIInputContrastKey: 1.08])
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        case .sepia:
            return image.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.9])
        case .chrome:
            return image.applyingFilter("CIPhotoEffectChrome")
        case .fade:
            return image.applyingFilter("CIPhotoEffectFade")
        case .instant:
            return image.applyingFilter("CIPhotoEffectInstant")
        case .warm:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 4700, y: 0),
            ])
        case .cool:
            return image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 9000, y: 0),
            ])
        case .underwater:
            // Water absorbs red first: bring it back and tame the blue/green cast.
            return image
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1.55, y: 0.15, z: 0.05, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0.95, z: 0.0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0.82, w: 0),
                    "inputBiasVector": CIVector(x: 0.01, y: 0, z: 0, w: 0),
                ])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08, kCIInputSaturationKey: 1.1])
        }
    }
}

struct FilterSettings: Equatable, Sendable {
    var kind: FilterKind = .none
    var intensity: Double = 1
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var vignette: Double = 0

    var isIdentity: Bool {
        (kind == .none || intensity == 0) && brightness == 0 && contrast == 1 && saturation == 1 && vignette == 0
    }
}

struct StabilizationSettings: Equatable, Sendable {
    var enabled = false
    /// 0...1 – how long a window the camera path is smoothed over (up to ~2 s each side).
    var strength: Double = 0.5
    /// Fraction of the frame that may be cropped away to hide the moving edges.
    var maxCrop: Double = 0.10
}

enum OverlayPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeft, topRight, bottomLeft, bottomRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeft: return "Top left"
        case .topRight: return "Top right"
        case .bottomLeft: return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

enum OverlayLayout: String, CaseIterable, Identifiable, Sendable {
    case vertical, horizontal
    var id: String { rawValue }
    var title: String { self == .vertical ? "Stacked" : "In a row" }
}

enum UnitSystem: String, CaseIterable, Identifiable, Sendable {
    case metric, imperial
    var id: String { rawValue }
    var title: String { self == .metric ? "Metric" : "Imperial" }
}

struct RGBAColor: Equatable, Sendable {
    var r: Double, g: Double, b: Double, a: Double
    static let white = RGBAColor(r: 1, g: 1, b: 1, a: 1)
}

struct OverlaySettings: Equatable, Sendable {
    var enabled = true
    var metrics: Set<OverlayMetric> = [.heartRate, .pace, .depth]
    var position: OverlayPosition = .bottomLeft
    var layout: OverlayLayout = .vertical
    var scale: Double = 1
    var textColor: RGBAColor = .white
    var backgroundOpacity: Double = 0.35
    var units: UnitSystem = .metric
    var showGraph = true
    var graphMetric: OverlayMetric = .heartRate
    /// Seconds added to the video clock to line it up with the watch clock.
    var timeOffset: Double = 0
}

struct AudioSettings: Equatable, Sendable {
    var originalVolume: Double = 1
    var musicURL: URL?
    var musicVolume: Double = 0.7
    var musicStartOffset: Double = 0
    var loopMusic = true
    var fadeIn: Double = 1
    var fadeOut: Double = 2
}

enum ExportPreset: String, CaseIterable, Identifiable {
    case hevcHighest, h264Highest, hevc4K, h264_1080, h264_720

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hevcHighest: return "HEVC – original resolution"
        case .h264Highest: return "H.264 – original resolution"
        case .hevc4K: return "HEVC – 4K"
        case .h264_1080: return "H.264 – 1080p"
        case .h264_720: return "H.264 – 720p"
        }
    }

    var avPreset: String {
        switch self {
        case .hevcHighest: return "AVAssetExportPresetHEVCHighestQuality"
        case .h264Highest: return "AVAssetExportPresetHighestQuality"
        case .hevc4K: return "AVAssetExportPresetHEVC3840x2160"
        case .h264_1080: return "AVAssetExportPreset1920x1080"
        case .h264_720: return "AVAssetExportPreset1280x720"
        }
    }
}

enum ExportContainer: String, CaseIterable, Identifiable {
    case mp4, mov
    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4" : "QuickTime (MOV)" }
}
