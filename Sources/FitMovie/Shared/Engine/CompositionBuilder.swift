import AVFoundation

/// The edited movie: trimmed/cut composition, the per-frame effects pipeline and the audio mix.
struct EditedMovie: @unchecked Sendable {
    let composition: AVComposition
    let videoComposition: AVVideoComposition
    let audioMix: AVAudioMix?
    let duration: Double

    /// - Parameter withEffects: false plays the plain edit (trim, cuts, audio) without the per-frame effects.
    func makePlayerItem(withEffects: Bool = true) -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        if withEffects { item.videoComposition = videoComposition }
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
    /// One clip played whole or trimmed.
    static func build(source: SourceVideo, timeline: EditTimeline, clipID: UUID = UUID(), audio: AudioSettings,
                      renderer: FrameRenderer) async throws -> EditedMovie {
        try await build(clips: [ClipInput(id: clipID, source: source, timeline: timeline)], audio: audio, renderer: renderer)
    }

    /// Plays the kept parts of every clip one after the other.
    /// - Parameter renderSize: output frame size; defaults to the first clip's display size.
    static func build(clips: [ClipInput], audio: AudioSettings, renderer: FrameRenderer,
                      renderSize: CGSize? = nil) async throws -> EditedMovie {
        let sources = clips.map(\.source)
        guard clips.contains(where: { !$0.timeline.keptRanges.isEmpty }) else { throw CompositionError.emptyEdit }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CompositionError.trackCreationFailed
        }
        // The compositor rotates every piece itself. The track transform only matters for plain playback without the
        // effects composition (the iOS Simulator fallback), where the first clip's orientation is the best guess.
        videoTrack.preferredTransform = clips.first?.source.preferredTransform ?? .identity

        var sourceAudioTrack: AVMutableCompositionTrack?
        if audio.originalVolume > 0, clips.contains(where: { $0.source.audioTrack != nil }) {
            sourceAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }

        var pieces: [EffectsComposition.Piece] = []
        var cursor = CMTime.zero
        for clip in clips {
            let source = clip.source
            let audioRange = try await source.audioTrack?.load(.timeRange)
            for range in clip.timeline.keptRanges {
                let timeRange = CMTimeRange(start: CMTime(secondsValue: range.lowerBound), end: CMTime(secondsValue: range.upperBound))
                try videoTrack.insertTimeRange(timeRange, of: source.videoTrack, at: cursor)
                if let sourceAudioTrack, let audioTrack = source.audioTrack, let audioRange {
                    // Audio is often a few ms shorter than video (GoPro, DJI); only insert the overlapping part.
                    let overlap = timeRange.intersection(audioRange)
                    if overlap.duration.seconds > 0.01 {
                        try? sourceAudioTrack.insertTimeRange(overlap, of: audioTrack, at: cursor + (overlap.start - timeRange.start))
                    }
                }
                let pieceStart = cursor
                let clipID = clip.id
                let sourceStart = range.lowerBound
                pieces.append(EffectsComposition.Piece(
                    timeRange: CMTimeRange(start: cursor, duration: timeRange.duration),
                    naturalSize: source.naturalSize, preferredTransform: source.preferredTransform
                ) { frame, time in
                    renderer.render(frame, clipID: clipID, sourceTime: sourceStart + (time - pieceStart).seconds)
                })
                cursor = cursor + timeRange.duration
            }
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

        let videoComposition = EffectsComposition.make(
            trackID: videoTrack.trackID, pieces: pieces,
            frameDuration: ProjectTimeline.frameDuration(sources),
            renderSize: renderSize ?? ProjectTimeline.renderSize(sources))

        let mix: AVMutableAudioMix?
        if mixParameters.isEmpty {
            mix = nil
        } else {
            mix = AVMutableAudioMix()
            mix?.inputParameters = mixParameters
        }

        return EditedMovie(composition: composition, videoComposition: videoComposition, audioMix: mix, duration: total.seconds)
    }

    /// A video composition over one clip's raw source, used for scrub previews of any source frame (including
    /// removed parts). Frames come out at the project's `renderSize`, like the player's.
    static func previewComposition(clipID: UUID, source: SourceVideo, renderSize: CGSize,
                                   renderer: FrameRenderer) -> AVVideoComposition {
        EffectsComposition.make(
            asset: source.asset, trackID: source.videoTrack.trackID, duration: CMTime(secondsValue: source.duration),
            naturalSize: source.naturalSize, preferredTransform: source.preferredTransform,
            frameDuration: source.frameDuration, renderSize: renderSize
        ) { frame, time in
            renderer.render(frame, clipID: clipID, sourceTime: time.seconds)
        }
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
