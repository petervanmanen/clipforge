import AVFoundation
import AppKit
import Combine
import CoreImage
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    // MARK: Source
    @Published private(set) var source: SourceVideo?
    @Published private(set) var thumbnails: [CGImage] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    // MARK: Edit settings
    @Published var timeline = EditTimeline(sourceDuration: 0) {
        didSet { if timeline != oldValue { pushSnapshot(); scheduleRebuild() } }
    }
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
    @Published private(set) var stabilizationAnalysis: StabilizationAnalysis?
    @Published private(set) var stabilizationProgress: Double?

    // MARK: Playback
    @Published private(set) var currentSourceTime: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var scrubImage: CGImage?
    @Published var markIn: Double?
    @Published var markOut: Double?

    // MARK: Export
    @Published var exportPreset: ExportPreset = .hevcHighest
    @Published var exportContainer: ExportContainer = .mp4
    @Published private(set) var exportProgress: Double?
    @Published private(set) var lastExportURL: URL?

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
    private var scrubGenerator: AVAssetImageGenerator?
    private var scrubRequest = 0

    init() {
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.scrubImage == nil else { return }
                self.currentSourceTime = self.timeline.sourceTime(forOutput: time.seconds)
            }
        }
        player.publisher(for: \.timeControlStatus)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in self?.isPlaying = status != .paused }
            .store(in: &cancellables)
    }

    // MARK: - Derived values

    var outputDuration: Double { timeline.outputDuration }

    /// Video start on the watch's UTC clock (before the fine offset).
    var videoStartDate: Date? {
        guard let created = source?.creationDate else { return nil }
        guard videoClockIsLocal else { return created }
        // The camera stored local wall-clock time as if it were UTC; undo the time-zone offset.
        let offset = activity?.utcOffset ?? TimeInterval(TimeZone.current.secondsFromGMT(for: created))
        return created.addingTimeInterval(-offset)
    }

    /// How the video overlaps the activity, for the sync UI.
    var syncStatus: String? {
        guard let activity else { return nil }
        guard let start = videoStartDate, let source else { return "The video has no recording date – use “Align to activity start”." }
        let videoStart = start.addingTimeInterval(overlay.timeOffset)
        let videoEnd = videoStart.addingTimeInterval(source.duration)
        if videoEnd < activity.startDate || videoStart > activity.endDate {
            return "⚠︎ The video doesn't overlap the activity. Check the clock option or align it."
        }
        let into = videoStart.timeIntervalSince(activity.startDate)
        return into >= 0 ? "Video starts \(formatTimecode(into, fractional: false)) into the activity."
            : "Video starts \(formatTimecode(-into, fractional: false)) before the activity."
    }

    // MARK: - Opening

    func openVideoPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = SourceVideo.contentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video from your iPhone, GoPro, DJI or Android device"
        if panel.runModal() == .OK, let url = panel.url { openVideo(url) }
    }

    func openVideo(_ url: URL) {
        isLoading = true
        Task {
            defer { isLoading = false }
            do {
                let loaded = try await SourceVideo.load(url: url)
                analysisTask?.cancel()
                player.replaceCurrentItem(with: nil)
                source = loaded
                stabilizationAnalysis = nil
                stabilizationPath = nil
                stabilizationProgress = nil
                stabilization.enabled = false
                markIn = nil
                markOut = nil
                currentSourceTime = 0
                lastExportURL = nil
                videoClockIsLocal = loaded.cameraClockIsProbablyLocal
                timeline = EditTimeline(sourceDuration: loaded.duration)
                scrubGenerator = makeScrubGenerator(for: loaded)
                pushSnapshot()
                rebuildNow()
                await loadThumbnails(for: loaded)
            } catch {
                errorMessage = "Couldn't open \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    private func loadThumbnails(for source: SourceVideo) async {
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
        if self.source?.url == source.url { thumbnails = images }
    }

    func loadFITPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "fit") ?? .data]
        panel.allowsOtherFileTypes = true
        panel.message = "Choose a .fit activity file from Suunto, Garmin, Coros, …"
        if panel.runModal() == .OK, let url = panel.url { loadFIT(url) }
    }

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
            if videoStartDate == nil { alignToActivityStart() }
            pushSnapshot()
        } catch {
            errorMessage = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func removeFIT() {
        activity = nil
        pushSnapshot()
    }

    /// Sets the offset so the first video frame matches the start of the activity.
    func alignToActivityStart() {
        guard let activity else { return }
        let start = videoStartDate ?? activity.startDate
        overlay.timeOffset = activity.startDate.timeIntervalSince(start).rounded()
    }

    func handleDrop(_ urls: [URL]) {
        for url in urls {
            let ext = url.pathExtension.lowercased()
            if ext == "fit" {
                loadFIT(url)
            } else if ["mp3", "m4a", "wav", "aac", "aiff", "aif", "caf", "flac"].contains(ext) {
                setMusic(url)
            } else {
                openVideo(url)
            }
        }
    }

    // MARK: - Music

    func chooseMusicPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = "Choose background music"
        if panel.runModal() == .OK, let url = panel.url { setMusic(url) }
    }

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
        s.keptRanges = timeline.keptRanges
        s.sourceDuration = timeline.sourceDuration
        s.filter = filter
        s.stabilization = stabilization
        if let analysis = stabilizationAnalysis, stabilization.enabled {
            if stabilizationPath == nil
                || stabilizationPathSettings?.strength != stabilization.strength
                || stabilizationPathSettings?.maxCrop != stabilization.maxCrop {
                stabilizationPath = Stabilizer.path(for: analysis, settings: stabilization)
                stabilizationPathSettings = stabilization
            }
            s.stabilizationPath = stabilizationPath
        }
        s.overlay = overlay
        s.activity = activity
        s.videoStartDate = videoStartDate ?? activity?.startDate
        renderState.snapshot = s
        refreshFrame()
    }

    private var stabilizationPath: StabilizationPath?
    private var stabilizationPathSettings: StabilizationSettings?

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

    private func rebuild() async {
        guard let source else { return }
        let sourceTime = currentSourceTime
        let wasPlaying = isPlaying
        do {
            let built = try await CompositionBuilder.build(source: source, timeline: timeline, audio: audio, renderer: renderer)
            guard !Task.isCancelled else { return }
            movie = built
            player.replaceCurrentItem(with: built.makePlayerItem())
            let t = CMTime(secondsValue: timeline.outputTime(forSource: sourceTime))
            await player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
            if wasPlaying { player.play() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Transport

    func togglePlay() {
        guard player.currentItem != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            if timeline.outputTime(forSource: currentSourceTime) >= outputDuration - 0.05 {
                player.seek(to: .zero)
            }
            player.play()
        }
    }

    func seek(toSource t: Double) {
        let clamped = min(max(0, t), timeline.sourceDuration)
        currentSourceTime = clamped
        let out = timeline.outputTime(forSource: clamped)
        player.seek(to: CMTime(secondsValue: out), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        guard let source else { return }
        player.pause()
        seek(toSource: currentSourceTime + Double(frames) / source.frameRate)
    }

    func jumpToStart() { seek(toSource: timeline.keptRanges.first?.lowerBound ?? 0) }

    // MARK: - Scrubbing (shows any source frame, including removed parts)

    private func makeScrubGenerator(for source: SourceVideo) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: source.asset)
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        let tolerance = CMTime(seconds: 0.5 / source.frameRate, preferredTimescale: 60_000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        Task {
            generator.videoComposition = try? await CompositionBuilder.previewComposition(source: source, renderer: renderer)
        }
        return generator
    }

    func scrub(toSource t: Double) {
        player.pause()
        currentSourceTime = min(max(0, t), timeline.sourceDuration)
        requestScrubFrame(at: currentSourceTime)
    }

    private func requestScrubFrame(at t: Double) {
        guard let generator = scrubGenerator else { return }
        scrubRequest += 1
        let request = scrubRequest
        generator.cancelAllCGImageGeneration()
        Task {
            guard let (image, _) = try? await generator.image(at: CMTime(secondsValue: t)) else { return }
            if request == self.scrubRequest, self.scrubGenerator === generator { self.scrubImage = image }
        }
    }

    func endScrub() {
        scrubRequest += 1
        scrubGenerator?.cancelAllCGImageGeneration()
        seek(toSource: currentSourceTime)
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            scrubImage = nil
        }
    }

    // MARK: - Trim & cut

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

    private var pendingTimeline: EditTimeline?

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
        if stabilization.enabled && stabilizationAnalysis == nil {
            if stabilizationProgress == nil { analyzeStabilization() }
            return
        }
        pushSnapshot()
    }

    func analyzeStabilization() {
        guard let source else { return }
        analysisTask?.cancel()
        stabilizationProgress = 0
        analysisTask = Task {
            do {
                let analysis = try await Task.detached(priority: .userInitiated) {
                    try await Stabilizer.analyze(source) { p in
                        Task { @MainActor [weak self] in
                            if self?.stabilizationProgress != nil { self?.stabilizationProgress = p }
                        }
                    }
                }.value
                guard self.source?.url == source.url else { return }
                stabilizationAnalysis = analysis
                stabilizationProgress = nil
                stabilizationPath = nil
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

    func exportPanel() {
        guard let source, movie != nil else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [exportContainer == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        panel.nameFieldStringValue = source.url.deletingPathExtension().lastPathComponent + "-edit." + exportContainer.rawValue
        if panel.runModal() == .OK, let url = panel.url { export(to: url) }
    }

    func export(to url: URL) {
        guard let source else { return }
        player.pause()
        exportProgress = 0
        exportTask = Task {
            do {
                // Build a fresh movie so export doesn't share compositor state with the player.
                let exportMovie = try await CompositionBuilder.build(source: source, timeline: timeline, audio: audio, renderer: renderer)
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
