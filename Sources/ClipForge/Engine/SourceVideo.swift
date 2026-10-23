import AVFoundation
import UniformTypeIdentifiers

enum VideoLoadError: LocalizedError {
    case noVideoTrack
    case notPlayable(String)

    var errorDescription: String? {
        switch self {
        case .noVideoTrack: return "The file has no video track."
        case .notPlayable(let codec): return "This Mac can't decode this video (codec \(codec))."
        }
    }
}

/// A loaded source clip: the asset plus the properties the editor needs.
struct SourceVideo: @unchecked Sendable {
    let url: URL
    let asset: AVURLAsset
    let videoTrack: AVAssetTrack
    let audioTrack: AVAssetTrack?
    let duration: Double
    let preferredTransform: CGAffineTransform
    /// Size as displayed (rotation applied).
    let displaySize: CGSize
    let frameRate: Double
    let frameDuration: CMTime
    let codec: String
    /// When recording started, as stored in the file's metadata.
    let creationDate: Date?

    /// File types offered in the open panel: iPhone (MOV/HEVC), GoPro (MP4/LRV), DJI (MP4/MOV), Android (MP4/3GP).
    static let contentTypes: [UTType] = {
        var types: [UTType] = [.movie, .video, .quickTimeMovie, .mpeg4Movie]
        for ext in ["lrv", "3gp", "m4v", "mts"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }()

    /// Camera brands that write the creation time in local time instead of UTC.
    var cameraClockIsProbablyLocal: Bool {
        let name = url.lastPathComponent.uppercased()
        return name.hasPrefix("GX") || name.hasPrefix("GH") || name.hasPrefix("GOPR") || name.hasPrefix("GP")
            || name.hasPrefix("DJI_")
    }

    static func load(url: URL) async throws -> SourceVideo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoLoadError.noVideoTrack
        }
        let (naturalSize, transform, nominalRate, minFrameDuration, formats) = try await video.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds

        let codec = formats.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? "?"
        if try await !video.load(.isDecodable) { throw VideoLoadError.notPlayable(codec) }

        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        let rate = nominalRate > 0 ? Double(nominalRate) : 30
        let frameDuration = minFrameDuration.isValid && minFrameDuration.seconds > 0
            ? minFrameDuration : CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))

        // Pick the first decodable, non-spatial audio track (iPhone spatial audio adds an APAC track).
        var audio: AVAssetTrack?
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let fmts = try await track.load(.formatDescriptions)
            let sub = fmts.first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? ""
            if sub == "apac" { continue }
            if try await track.load(.isDecodable) { audio = track; break }
        }

        return SourceVideo(
            url: url,
            asset: asset,
            videoTrack: video,
            audioTrack: audio,
            duration: duration,
            preferredTransform: transform,
            displaySize: CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded()),
            frameRate: rate,
            frameDuration: frameDuration,
            codec: codec,
            creationDate: await loadCreationDate(asset)
        )
    }

    private static func loadCreationDate(_ asset: AVURLAsset) async -> Date? {
        if let item = try? await asset.load(.creationDate) {
            if let date = try? await item.load(.dateValue) { return date }
            if let string = try? await item.load(.stringValue) {
                let iso = ISO8601DateFormatter()
                if let d = iso.date(from: string) { return d }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd HH:mm:ss"] {
                    f.dateFormat = format
                    if let d = f.date(from: string) { return d }
                }
            }
        }
        return nil
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
    }
}
