import AVFoundation
import Combine
import CoreImage
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// A kind of file the user can bring into the editor.
enum ImportKind: String, Identifiable {
    /// Video that starts a new project.
    case video
    /// Video added to the end of the current project.
    case clip
    case fit, music

    var id: String { rawValue }

    var contentTypes: [UTType] {
        switch self {
        case .video, .clip: return SourceVideo.contentTypes
        case .fit: return [UTType(filenameExtension: "fit") ?? .data, .data]
        case .music: return [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        }
    }

    var allowsMultipleSelection: Bool { self == .video || self == .clip }

    static func guess(for url: URL) -> ImportKind {
        let ext = url.pathExtension.lowercased()
        if ext == "fit" { return .fit }
        if ["mp3", "m4a", "wav", "aac", "aiff", "aif", "caf", "flac"].contains(ext) { return .music }
        return .video
    }
}

@MainActor
final class EditorModel: ObservableObject {
    // MARK: Project
    /// The clips in playback order. Each has its own trim/cuts and stabilization analysis.
    @Published private(set) var clips: [Clip] = []
    /// The clip shown in the timeline strip and edited by the Trim panel; follows the playhead.
    @Published private(set) var selectedClipID: UUID?
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// The inspector tab on screen (kept here so toolbar buttons can switch to it).
    @Published var inspectorTab: InspectorTab = .trim
    /// Set to ask the platform UI to show a file importer for this kind of file.
    @Published var importRequest: ImportKind?

    // MARK: Edit settings (whole project)
    @Published var filter = FilterSettings() {
        didSet { if filter != oldValue { pushSnapshot() } }
    }
    @Published var stabilization = StabilizationSettings() {
        didSet { if stabilization != oldValue { stabilizationChanged() } }
    }
    @Published var overlay = OverlaySettings() {
        didSet { if overlay != oldValue { pushSnapshot() } }
    }
    @Published var audio = AudioSettings() {
        didSet { if audio != oldValue { scheduleRebuild() } }
    }
    @Published var videoClockIsLocal = false {
        didSet { if videoClockIsLocal != oldValue { pushSnapshot() } }
    }

    // MARK: Activity / music / analysis state
    @Published private(set) var activity: FITActivity?
    @Published private(set) var musicDuration: Double = 0
    @Published private(set) var stabilizationProgress: Double?

    // MARK: Playback
    /// Playhead position in the selected clip's source.
    @Published private(set) var currentSourceTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var scrubImage: CGImage?
    /// True when live playback can't render effects (the iOS Simulator can't play any video composition).
    /// Playback then shows the plain edit and effects appear on the paused frame; export is unaffected.
    @Published private(set) var previewIsLimited = false
    @Published var markIn: Double?
    @Published var markOut: Double?

    // MARK: Export
    @Published var exportPreset: ExportPreset = .hevcHighest
    @Published var exportContainer: ExportContainer = .mp4
    @Published private(set) var exportProgress: Double?
    @Published private(set) var lastExportURL: URL? { didSet { savedToPhotos = false } }
    /// iOS: whether `lastExportURL` has been added to the photo library.
    @Published var savedToPhotos = false

    let player = AVPlayer()
    let renderState = RenderState()
    private(set) lazy var renderer = FrameRenderer(state: renderState)

    private var movie: EditedMovie?
    private var rebuildTask: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var refreshPending = false
    private var timeObserver: Any?
    private var cancellables: Set<AnyCancellable> = []
    private var scrubGenerators: [UUID: AVAssetImageGenerator] = [:]
    private var scrubGeneratorSize: CGSize = .zero
    private var scrubRequest = 0
    private var itemStatusObservation: AnyCancellable?
    private var stabilizationPaths: [UUID: StabilizationPath] = [:]
    private var stabilizationPathSettings: StabilizationSettings?
    private var pendingTimeline: EditTimeline?

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.scrubImage == nil, self.isPlaying else { return }
                self.followPlayhead(outputTime: time.seconds)
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self else { return }
                self.isPlaying = status != .paused
                guard self.previewIsLimited else { return }
                if self.isPlaying { self.scrubImage = nil } else { self.showStillFrame() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Selected clip

    private var selectedIndex: Int? { clips.firstIndex { $0.id == selectedClipID } }
    var selectedClip: Clip? { selectedIndex.map { clips[$0] } }
    var source: SourceVideo? { selectedClip?.source }
    var thumbnails: [CGImage] { selectedClip?.thumbnails ?? [] }

    /// The selected clip's trim and cuts.
    var timeline: EditTimeline {
        get { selectedClip?.timeline ?? EditTimeline(sourceDuration: 0) }
        set {
            guard let i = selectedIndex, clips[i].timeline != newValue else { return }
            clips[i].timeline = newValue
            timelineChanged()
        }
    }

    // MARK: - Derived values

    var segments: [ClipSegment] { ProjectTimeline.segments(clips.map { ($0.id, $0.timeline) }) }
    var outputDuration: Double { clips.reduce(0) { $0 + $1.timeline.outputDuration } }
    var renderSize: CGSize { ProjectTimeline.renderSize(clips.map(\.source)) }

    /// Playhead position on the combined output timeline.
    var currentOutputTime: Double {
        guard let id = selectedClipID else { return 0 }
        return ProjectTimeline.outputTime(clipID: id, sourceTime: currentSourceTime, in: segments) ?? 0
    }

    var isStabilizationAnalyzed: Bool { !clips.isEmpty && clips.allSatisfy { $0.stabilizationAnalysis != nil } }

    /// Recording start of every clip on the watch's UTC clock (before the fine offset). Clips without a recording
    /// date are assumed to follow the previous clip; the first falls back to the activity start.
    var videoStartDates: [UUID: Date] {
        var result: [UUID: Date] = [:]
        var previousEnd: Date?
        for clip in clips {
            var start: Date?
            if let created = clip.source.creationDate {
                if videoClockIsLocal {
                    // The camera stored local wall-clock time as if it were UTC; undo the time-zone offset.
                    let offset = activity?.utcOffset ?? TimeInterval(TimeZone.current.secondsFromGMT(for: created))
                    start = created.addingTimeInterval(-offset)
                } else {
                    start = created
                }
            }
            start = start ?? previousEnd ?? activity?.startDate
            if let start {
                result[clip.id] = start
                previousEnd = start.addingTimeInterval(clip.source.duration)
            }
        }
        return result
    }

    /// The selected clip's recording start (watch clock), if known.
    var videoStartDate: Date? { selectedClipID.flatMap { videoStartDates[$0] } }

    /// How the selected clip overlaps the activity, for the sync UI.
    var syncStatus: String? {
        guard let activity else { return nil }
        let label = clips.count > 1 ? "This clip" : "The video"
        guard let start = videoStartDate, let source else {
            return "\(label) has no recording date – use “Align to activity start”."
        }
        let clipStart = start.addingTimeInterval(overlay.timeOffset)
        let clipEnd = clipStart.addingTimeInterval(source.duration)
        if clipEnd < activity.startDate || clipStart > activity.endDate {
            return "⚠︎ \(label) doesn't overlap the activity. Check the clock option or align it."
        }
        let into = clipStart.timeIntervalSince(activity.startDate)
        return into >= 0 ? "\(label) starts \(formatTimecode(into, fractional: false)) into the activity."
            : "\(label) starts \(formatTimecode(-into, fractional: false)) before the activity."
    }

    // MARK: - Importing

    func requestImport(_ kind: ImportKind) {
        importRequest = kind
    }

    /// Opens a file picked in a file importer, dropped on the window or sent from another app.
    /// Videos without an explicit kind start a project when there is none, and are added to it otherwise.
    func importFile(_ url: URL, as kind: ImportKind? = nil) {
        importFiles([url], as: kind)
    }

    /// Imports files in order. Videos are loaded one after another so clips keep the chosen order.
    func importFiles(_ urls: [URL], as kind: ImportKind? = nil) {
        guard !urls.isEmpty else { return }
        let startsNewProject = kind == .video
        let hasVideos = urls.contains { [.video, .clip].contains(kind ?? ImportKind.guess(for: $0)) }
        if hasVideos { isLoading = true }
        Task {
            defer { if hasVideos { isLoading = false } }
            var videos: [URL] = []
            for url in urls {
                do {
                    let local = try await Self.localCopy(of: url)
                    switch kind ?? ImportKind.guess(for: url) {
                    case .video, .clip: videos.append(local)
                    case .fit: loadFIT(local)
                    case .music: setMusic(local)
                    }
                } catch {
                    errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
            guard !videos.isEmpty else { return }
            await addVideos(videos, replacingProject: startsNewProject || clips.isEmpty)
        }
    }

    /// On iOS, picked files are security-scoped and only readable for a moment, so they are copied into the
    /// app's temporary folder (keeping the file name, which identifies GoPro/DJI clips). macOS reads them in place.
    private static func localCopy(of url: URL) async throws -> URL {
        #if os(macOS)
        return url
        #else
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // Files the app already owns (e.g. from the photo picker) don't need another copy.
        if url.path.hasPrefix(FileManager.default.temporaryDirectory.path) { return url }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(url.lastPathComponent)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.copyItem(at: url, to: destination)
        }.value
        return destination
        #endif
    }

    /// Loads videos and adds them as clips (in order), or starts a new project with them.
    func addVideos(_ urls: [URL], replacingProject: Bool) async {
        var loaded: [Clip] = []
        for url in urls {
            do {
                loaded.append(Clip(source: try await SourceVideo.load(url: url)))
            } catch {
                errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
        guard !loaded.isEmpty else { return }

        if replacingProject {
            analysisTask?.cancel()
            player.replaceCurrentItem(with: nil)
            clips = []
            scrubGenerators = [:]
            stabilizationPaths = [:]
            stabilizationProgress = nil
            stabilization.enabled = false
            lastExportURL = nil
            videoClockIsLocal = loaded[0].source.cameraClockIsProbablyLocal
        }
        let firstNew = loaded[0].id
        clips.append(contentsOf: loaded)
        clipsChanged()
        select(firstNew)
        if stabilization.enabled { analyzeStabilization() }
        for clip in loaded { await loadThumbnails(for: clip) }
    }

    private func loadThumbnails(for clip: Clip) async {
        let source = clip.source
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let count = 24
        let times = (0..<count).map { CMTime(secondsValue: source.duration * (Double($0) + 0.5) / Double(count)) }
        var images: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { images.append(image) }
        }
        if let i = clips.firstIndex(where: { $0.id == clip.id }) { clips[i].thumbnails = images }
    }

    // MARK: - Managing clips

    func select(_ id: UUID) {
        guard clips.contains(where: { $0.id == id }) else { return }
        if selectedClipID != id {
            selectedClipID = id
            markIn = nil
            markOut = nil
        }
        seek(toSource: timeline.keptRanges.first?.lowerBound ?? 0)
    }

    func removeClip(_ id: UUID) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips.remove(at: i)
        scrubGenerators[id] = nil
        stabilizationPaths[id] = nil
        if clips.isEmpty {
            selectedClipID = nil
            player.replaceCurrentItem(with: nil)
            movie = nil
            scrubImage = nil
            pushSnapshot()
            return
        }
        clipsChanged()
        if selectedClipID == id { select(clips[min(i, clips.count - 1)].id) }
    }

    func canMoveClip(_ id: UUID, by offset: Int) -> Bool {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return false }
        return clips.indices.contains(i + offset)
    }

    func moveClip(_ id: UUID, by offset: Int) {
        guard canMoveClip(id, by: offset), let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips.swapAt(i, i + offset)
        clipsChanged()
    }

    /// Clip order, membership or the first clip (which sets the frame size) changed.
    private func clipsChanged() {
        if scrubGeneratorSize != renderSize {
            scrubGenerators = [:]
            scrubGeneratorSize = renderSize
        }
        pushSnapshot()
        rebuildNow()
    }

    private func timelineChanged() {
        pushSnapshot()
        scheduleRebuild()
    }

    // MARK: - Activity

    func loadFIT(_ url: URL) {
        do {
            let loaded = try FITActivity.load(url: url)
            activity = loaded
            var o = overlay
            let available = Set(loaded.availableMetrics)
            o.metrics = loaded.isDive ? [.depth, .heartRate, .temperature] : [.heartRate, .pace]
            o.metrics.formIntersection(available)
            if o.metrics.isEmpty { o.metrics = [.elapsed] }
            o.graphMetric = loaded.isDive && available.contains(.depth) ? .depth
                : available.contains(.heartRate) ? .heartRate : (loaded.availableMetrics.first { $0.isGraphable } ?? .heartRate)
            o.timeOffset = 0
            o.enabled = true
            overlay = o
            pushSnapshot()
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeFIT() {
        activity = nil
        pushSnapshot()
    }

    /// Sets the offset so the first clip's first frame matches the start of the activity.
    func alignToActivityStart() {
        guard let activity else { return }
        let start = clips.first.flatMap { videoStartDates[$0.id] } ?? activity.startDate
        overlay.timeOffset = activity.startDate.timeIntervalSince(start).rounded()
    }

    func handleDrop(_ urls: [URL]) {
        importFiles(urls)
    }

    // MARK: - Music

    func setMusic(_ url: URL?) {
        guard let url else {
            audio.musicURL = nil
            musicDuration = 0
            return
        }
        Task {
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            guard duration > 0 else {
                errorMessage = "Couldn't read audio from \(url.lastPathComponent)."
                return
            }
            musicDuration = duration
            var a = audio
            a.musicURL = url
            a.musicStartOffset = 0
            audio = a
        }
    }

    // MARK: - Snapshot & composition

    private func pushSnapshot() {
        var s = RenderSnapshot()
        s.segments = segments
        s.renderSize = renderSize
        s.filter = filter
        s.stabilization = stabilization
        s.overlay = overlay
        s.activity = activity

        if stabilizationPathSettings?.strength != stabilization.strength || stabilizationPathSettings?.maxCrop != stabilization.maxCrop {
            stabilizationPaths = [:]
            stabilizationPathSettings = stabilization
        }
        let starts = videoStartDates
        for clip in clips {
            var info = RenderSnapshot.ClipInfo(videoStartDate: starts[clip.id])
            if stabilization.enabled, let analysis = clip.stabilizationAnalysis {
                if stabilizationPaths[clip.id] == nil {
                    stabilizationPaths[clip.id] = Stabilizer.path(for: analysis, settings: stabilization)
                }
                info.stabilizationPath = stabilizationPaths[clip.id]
            }
            s.clips[clip.id] = info
        }
        let windows = clips.compactMap { clip in starts[clip.id].map { ($0, $0.addingTimeInterval(clip.source.duration)) } }
        if let lower = windows.map(\.0).min(), let upper = windows.map(\.1).max() { s.overlayWindow = lower...upper }

        renderState.snapshot = s
        refreshFrame()
    }

    /// Re-renders the paused frame after an effect setting changed.
    private func refreshFrame() {
        if scrubImage != nil {
            requestScrubFrame(at: currentSourceTime)
            return
        }
        guard !isPlaying, !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.refreshPending = false
            if let item = self.player.currentItem, let vc = item.videoComposition {
                item.videoComposition = vc.mutableCopy() as? AVVideoComposition
            }
        }
    }

    private func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            await rebuild()
        }
    }

    private func rebuildNow() {
        rebuildTask?.cancel()
        rebuildTask = Task { await rebuild() }
    }

    private var clipInputs: [ClipInput] { clips.map { ClipInput(id: $0.id, source: $0.source, timeline: $0.timeline) } }

    private func rebuild() async {
        guard !clips.isEmpty else { return }
        let wasPlaying = isPlaying
        do {
            let built = try await CompositionBuilder.build(clips: clipInputs, audio: audio, renderer: renderer, renderSize: renderSize)
            guard !Task.isCancelled else { return }
            movie = built
            let item = built.makePlayerItem(withEffects: !previewIsLimited)
            watchForPlaybackFailure(of: item, movie: built)
            player.replaceCurrentItem(with: item)
            await player.seek(to: CMTime(secondsValue: currentOutputTime), toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() } else { showStillFrame() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Falls back to plain playback if the player can't render the effects composition.
    private func watchForPlaybackFailure(of item: AVPlayerItem, movie: EditedMovie) {
        itemStatusObservation = item.publisher(for: \.status)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self, status == .failed, self.player.currentItem === item else { return }
                guard item.videoComposition != nil else {
                    self.errorMessage = "Playback failed: \(item.error?.localizedDescription ?? "unknown error")"
                    return
                }
                self.previewIsLimited = true
                let plain = movie.makePlayerItem(withEffects: false)
                self.watchForPlaybackFailure(of: plain, movie: movie)
                self.player.replaceCurrentItem(with: plain)
                self.seek(toSource: self.currentSourceTime)
            }
    }

    /// In limited-preview mode, shows the paused frame with all effects (rendered like a scrub frame).
    private func showStillFrame() {
        guard previewIsLimited, !isPlaying else { return }
        requestScrubFrame(at: currentSourceTime)
    }

    // MARK: - Transport

    /// Keeps the selected clip and source playhead in step with playback.
    private func followPlayhead(outputTime: Double) {
        guard let (clipID, sourceTime) = ProjectTimeline.locate(outputTime, in: segments) else { return }
        if clipID != selectedClipID {
            selectedClipID = clipID
            markIn = nil
            markOut = nil
        }
        currentSourceTime = sourceTime
    }

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if currentOutputTime >= outputDuration - 0.05 {
                if let first = clips.first { selectedClipID = first.id }
                currentSourceTime = timeline.keptRanges.first?.lowerBound ?? 0
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    /// Moves the playhead to a source time of the selected clip.
    func seek(toSource t: Double) {
        let clamped = min(max(0, t), timeline.sourceDuration)
        currentSourceTime = clamped
        player.seek(to: CMTime(secondsValue: currentOutputTime), toleranceBefore: .zero, toleranceAfter: .zero)
        showStillFrame()
    }

    func step(frames: Int) {
        guard let source else { return }
        player.pause()
        seek(toSource: currentSourceTime + Double(frames) / source.frameRate)
    }

    func jumpToStart() {
        guard let first = clips.first else { return }
        select(first.id)
    }

    // MARK: - Scrubbing (shows any frame of the selected clip, including removed parts)

    private func scrubGenerator(for clip: Clip) -> AVAssetImageGenerator {
        if let existing = scrubGenerators[clip.id] { return existing }
        let source = clip.source
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let tolerance = CMTime(seconds: 0.5 / source.frameRate, preferredTimescale: 60_000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        generator.videoComposition = CompositionBuilder.previewComposition(
            clipID: clip.id, source: source, renderSize: renderSize, renderer: renderer)
        scrubGenerators[clip.id] = generator
        scrubGeneratorSize = renderSize
        return generator
    }

    func scrub(toSource t: Double) {
        player.pause()
        currentSourceTime = min(max(0, t), timeline.sourceDuration)
        requestScrubFrame(at: currentSourceTime)
    }

    private func requestScrubFrame(at t: Double) {
        guard let clip = selectedClip else { return }
        let generator = scrubGenerator(for: clip)
        scrubRequest += 1
        let request = scrubRequest
        generator.cancelAllCGImageGeneration()
        Task {
            guard let (image, _) = try? await generator.image(at: CMTime(secondsValue: t)) else { return }
            if request == self.scrubRequest, self.selectedClipID == clip.id { self.scrubImage = image }
        }
    }

    func endScrub() {
        scrubRequest += 1
        if let id = selectedClipID { scrubGenerators[id]?.cancelAllCGImageGeneration() }
        seek(toSource: currentSourceTime)
        guard !previewIsLimited else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            scrubImage = nil
        }
    }

    // MARK: - Trim & cut (selected clip)

    func dragTrimStart(to t: Double) {
        var tl = timeline
        tl.setTrimStart(t)
        trimPreview(tl, at: tl.trimStart)
    }

    func dragTrimEnd(to t: Double) {
        var tl = timeline
        tl.setTrimEnd(t)
        trimPreview(tl, at: tl.trimEnd)
    }

    private func trimPreview(_ tl: EditTimeline, at t: Double) {
        pendingTimeline = tl
        scrub(toSource: t)
        objectWillChange.send()
    }

    /// Timeline as displayed, including an in-progress handle drag.
    var displayedTimeline: EditTimeline { pendingTimeline ?? timeline }

    func endTrimDrag() {
        if let pending = pendingTimeline {
            pendingTimeline = nil
            timeline = pending
        }
        endScrub()
    }

    func setTrimStartToPlayhead() { timeline.setTrimStart(currentSourceTime) }
    func setTrimEndToPlayhead() { timeline.setTrimEnd(currentSourceTime) }
    func setMarkIn() { markIn = currentSourceTime; if let o = markOut, o <= currentSourceTime { markOut = nil } }
    func setMarkOut() { markOut = currentSourceTime; if let i = markIn, i >= currentSourceTime { markIn = nil } }

    var canRemoveSelection: Bool {
        guard let i = markIn, let o = markOut else { return false }
        return o - i >= EditTimeline.minimumSegment
    }

    func removeSelection() {
        guard let i = markIn, let o = markOut, canRemoveSelection else { return }
        timeline.addCut(start: i, end: o)
        markIn = nil
        markOut = nil
        seek(toSource: o)
    }

    func clearSelection() {
        markIn = nil
        markOut = nil
    }

    // MARK: - Stabilization

    private func stabilizationChanged() {
        if stabilization.enabled && !isStabilizationAnalyzed {
            if stabilizationProgress == nil { analyzeStabilization() }
            return
        }
        pushSnapshot()
    }

    /// Analyzes every clip that hasn't been analyzed yet, one after another.
    func analyzeStabilization(reanalyze: Bool = false) {
        guard !clips.isEmpty else { return }
        analysisTask?.cancel()
        if reanalyze {
            for i in clips.indices { clips[i].stabilizationAnalysis = nil }
            stabilizationPaths = [:]
        }
        let pending = clips.filter { $0.stabilizationAnalysis == nil }.map { (id: $0.id, source: $0.source) }
        guard !pending.isEmpty else { return }
        stabilizationProgress = 0
        analysisTask = Task {
            do {
                for (index, item) in pending.enumerated() {
                    let source = item.source
                    let analysis = try await Task.detached(priority: .userInitiated) {
                        try await Stabilizer.analyze(source) { p in
                            Task { @MainActor [weak self] in
                                if self?.stabilizationProgress != nil {
                                    self?.stabilizationProgress = (Double(index) + p) / Double(pending.count)
                                }
                            }
                        }
                    }.value
                    if let i = clips.firstIndex(where: { $0.id == item.id }) {
                        clips[i].stabilizationAnalysis = analysis
                        stabilizationPaths[item.id] = nil
                    }
                }
                stabilizationProgress = nil
                stabilization.enabled = true
                pushSnapshot()
            } catch {
                stabilizationProgress = nil
                if !(error is CancellationError) { errorMessage = "Stabilization analysis failed: \(error.localizedDescription)" }
            }
        }
    }

    func cancelAnalysis() {
        analysisTask?.cancel()
        stabilizationProgress = nil
        stabilization.enabled = false
    }

    // MARK: - Export

    var exportFileName: String {
        (clips.first?.source.url.deletingPathExtension().lastPathComponent ?? "FitMovie") + "-edit." + exportContainer.rawValue
    }

    /// macOS asks where to save; iOS renders into a temporary file that the UI then saves to Photos or shares.
    func requestExport() {
        guard !clips.isEmpty, movie != nil, exportProgress == nil else { return }
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportContainer == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = exportFileName
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
        #else
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        export(to: folder.appendingPathComponent(exportFileName))
        #endif
    }

    func export(to url: URL) {
        guard !clips.isEmpty else { return }
        player.pause()
        exportProgress = 0
        let inputs = clipInputs
        let size = renderSize
        exportTask = Task {
            do {
                // Build a fresh movie so export doesn't share compositor state with the player.
                let exportMovie = try await CompositionBuilder.build(clips: inputs, audio: audio, renderer: renderer, renderSize: size)
                try await VideoExporter.export(exportMovie, to: url, preset: exportPreset, container: exportContainer) { p in
                    Task { @MainActor [weak self] in
                        if self?.exportProgress != nil { self?.exportProgress = p }
                    }
                }
                exportProgress = nil
                lastExportURL = url
            } catch {
                exportProgress = nil
                if !(error is CancellationError) { errorMessage = "Export failed: \(error.localizedDescription)" }
            }
        }
    }

    func cancelExport() {
        exportTask?.cancel()
        exportProgress = nil
    }
}
