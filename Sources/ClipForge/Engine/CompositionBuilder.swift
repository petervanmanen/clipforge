import AVFoundation

/// The edited movie: trimmed/cut composition, the per-frame effects pipeline and the audio mix.
struct EditedMovie: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: Double

    func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

enum CompositionError: LocalizedError {
    case emptyEdit
    case trackCreationFailed

    var errorDescription: String? {
        switch self {
        case .emptyEdit: return "Nothing is left after trimming."
        case .trackCreationFailed: return "Couldn't create the edited movie."
        }
    }
}

enum CompositionBuilder {
    static func build(source: SourceVideo, timeline: EditTimeline, audio: AudioSettings, renderer: FrameRenderer) async throws -> EditedMovie {
        let kept = timeline.keptRanges
        guard !kept.isEmpty else { throw CompositionError.emptyEdit }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.trackCreationFailed
        }
        videoTrack.preferredTransform = source.preferredTransform

        var sourceAudioTrack: AVMutableCompositionTrack?
        var sourceAudioRange = CMTimeRange.invalid
        if let audioTrack = source.audioTrack, audio.originalVolume > 0 {
            sourceAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            sourceAudioRange = try await audioTrack.load(.timeRange)
        }

        var cursor = CMTime.zero
        for range in kept {
            let timeRange = CMTimeRange(start: CMTime(secondsValue: range.lowerBound), end: CMTime(secondsValue: range.upperBound))
            try videoTrack.insertTimeRange(timeRange, of: source.videoTrack, at: cursor)
            if let sourceAudioTrack, let audioTrack = source.audioTrack {
                // Audio is often a few ms shorter than video (GoPro, DJI); only insert the overlapping part.
                let overlap = timeRange.intersection(sourceAudioRange)
                if overlap.duration.seconds > 0.01 {
                    try? sourceAudioTrack.insertTimeRange(overlap, of: audioTrack, at: cursor + (overlap.start - timeRange.start))
                }
            }
            cursor = cursor + timeRange.duration
        }
        let total = cursor

        var mixParameters: [AVAudioMixInputParameters] = []
        if let sourceAudioTrack {
            let p = AVMutableAudioMixInputParameters(track: sourceAudioTrack)
            p.setVolume(Float(audio.originalVolume), at: .zero)
            mixParameters.append(p)
        }

        if let musicURL = audio.musicURL {
            let musicAsset = AVURLAsset(url: musicURL)
            if let musicSource = try await musicAsset.loadTracks(withMediaType: .audio).first,
               let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let musicDuration = try await musicSource.load(.timeRange).end
                var at = CMTime.zero
                var from = CMTime(secondsValue: min(max(0, audio.musicStartOffset), max(0, musicDuration.seconds - 0.1)))
                while at < total {
                    let length = CMTimeMinimum(musicDuration - from, total - at)
                    if length.seconds < 0.05 { break }
                    try musicTrack.insertTimeRange(CMTimeRange(start: from, duration: length), of: musicSource, at: at)
                    at = at + length
                    from = .zero
                    if !audio.loopMusic { break }
                }

                let p = AVMutableAudioMixInputParameters(track: musicTrack)
                let volume = Float(audio.musicVolume)
                let end = at
                let fadeIn = min(audio.fadeIn, end.seconds / 2)
                let fadeOut = min(audio.fadeOut, end.seconds / 2)
                if fadeIn > 0 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: volume,
                                    timeRange: CMTimeRange(start: .zero, duration: CMTime(secondsValue: fadeIn)))
                } else {
                    p.setVolume(volume, at: .zero)
                }
                if fadeOut > 0 {
                    let start = end - CMTime(secondsValue: fadeOut)
                    p.setVolume(volume, at: CMTime(secondsValue: fadeIn))
                    p.setVolumeRamp(fromStartVolume: volume, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: start, end: end))
                }
                mixParameters.append(p)
            }
        }

        let videoComposition = try await AVMutableVideoComposition.videoComposition(with: composition) { request in
            let output = renderer.render(request.sourceImage, outputTime: request.compositionTime.seconds)
            request.finish(with: output, context: nil)
        }
        videoComposition.frameDuration = source.frameDuration
        videoComposition.renderSize = source.displaySize

        let mix: AVMutableAudioMix?
        if mixParameters.isEmpty {
            mix = nil
        } else {
            mix = AVMutableAudioMix()
            mix?.inputParameters = mixParameters
        }

        return EditedMovie(composition: composition, videoComposition: videoComposition, audioMix: mix, duration: total.seconds)
    }

    /// A video composition over the raw source, used for scrub previews of any source frame (including cut parts).
    static func previewComposition(source: SourceVideo, renderer: FrameRenderer) async throws -> AVVideoComposition {
        let vc = try await AVMutableVideoComposition.videoComposition(with: source.asset) { request in
            let output = renderer.render(request.sourceImage, sourceTime: request.compositionTime.seconds)
            request.finish(with: output, context: nil)
        }
        vc.frameDuration = source.frameDuration
        return vc
    }
}

enum VideoExporter {
    static func export(_ movie: EditedMovie, to url: URL, preset: ExportPreset, container: ExportContainer,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: movie.composition, presetName: preset.avPreset) else {
            throw CompositionError.trackCreationFailed
        }
        session.videoComposition = movie.videoComposition
        session.audioMix = movie.audioMix
        session.shouldOptimizeForNetworkUse = true

        try? FileManager.default.removeItem(at: url)

        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        try await session.export(to: url, as: container == .mp4 ? .mp4 : .mov)
        progress(1)
    }
}
