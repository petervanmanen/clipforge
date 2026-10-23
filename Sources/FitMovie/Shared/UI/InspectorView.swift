import CoreImage
import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    case trim, stabilize, filters, overlay, audio, export
    var id: String { rawValue }

    var title: String {
        switch self {
        case .trim: return "Trim"
        case .stabilize: return "Stabilize"
        case .filters: return "Filters"
        case .overlay: return "Data"
        case .audio: return "Audio"
        case .export: return "Export"
        }
    }

    var systemImage: String {
        switch self {
        case .trim: return "scissors"
        case .stabilize: return "camera.metering.center.weighted"
        case .filters: return "camera.filters"
        case .overlay: return "heart.text.square"
        case .audio: return "music.note"
        case .export: return "square.and.arrow.up"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { t in
                    Button { model.inspectorTab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.systemImage).font(.system(size: 15))
                            Text(t.title).font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(model.inspectorTab == t ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(model.inspectorTab == t ? Color.accentColor : .secondary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Divider()
            ScrollView {
                Group {
                    switch model.inspectorTab {
                    case .trim: TrimPanel()
                    case .stabilize: StabilizePanel()
                    case .filters: FiltersPanel()
                    case .overlay: OverlayPanel()
                    case .audio: AudioPanel()
                    case .export: ExportPanel()
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Shared bits

struct PanelSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

private func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

func platformHint(mac: String, phone: String) -> String {
    #if os(macOS)
    mac
    #else
    phone
    #endif
}

// MARK: - Trim

private struct TrimPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        PanelSection(title: "Start & end") {
            row("Start", model.timeline.trimStart) { model.setTrimStartToPlayhead() }
            row("End", model.timeline.trimEnd) { model.setTrimEndToPlayhead() }
            Text(platformHint(
                mac: "Drag the blue handles on the timeline, or use [ and ] to set start/end at the playhead.",
                phone: "Drag the blue handles on the timeline, or set start/end at the playhead."))
                .font(.caption).foregroundStyle(.secondary)
        }

        PanelSection(title: "Remove a part") {
            HStack {
                Button("Mark In") { model.setMarkIn() }.buttonStyle(.bordered)
                Button("Mark Out") { model.setMarkOut() }.buttonStyle(.bordered)
                Spacer()
                if model.markIn != nil || model.markOut != nil {
                    Button("Clear") { model.clearSelection() }.buttonStyle(.borderless)
                }
            }
            HStack {
                Text("In \(model.markIn.map { formatTimecode($0) } ?? "–")")
                Spacer()
                Text("Out \(model.markOut.map { formatTimecode($0) } ?? "–")")
            }
            .font(.callout.monospacedDigit())
            .foregroundStyle(.secondary)
            Button {
                model.removeSelection()
            } label: {
                Label("Remove Selection", systemImage: "scissors").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(!model.canRemoveSelection)
            Text(platformHint(
                mac: "Move the playhead, press I and O to mark a part in the middle, then remove it.",
                phone: "Move the playhead, mark the start (In) and end (Out) of a part in the middle, then remove it."))
                .font(.caption).foregroundStyle(.secondary)
        }

        PanelSection(title: "Removed parts") {
            if model.timeline.cuts.isEmpty {
                Text("None").foregroundStyle(.secondary)
            } else {
                ForEach(model.timeline.cuts) { cut in
                    HStack {
                        Image(systemName: "scissors").foregroundStyle(.red)
                        Button("\(formatTimecode(cut.start)) – \(formatTimecode(cut.end))") { model.seek(toSource: cut.start) }
                            .buttonStyle(.plain)
                            .font(.callout.monospacedDigit())
                        Text(String(format: "%.1fs", cut.duration)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.timeline.removeCut(id: cut.id) } label: { Image(systemName: "arrow.uturn.backward") }
                            .buttonStyle(.borderless)
                            .help("Restore this part")
                    }
                }
            }
        }

        PanelSection(title: "Result") {
            HStack {
                Text("Length")
                Spacer()
                Text(formatTimecode(model.outputDuration)).monospacedDigit()
            }
            if let source = model.source {
                HStack {
                    Text("Source")
                    Spacer()
                    Text("\(Int(source.displaySize.width))×\(Int(source.displaySize.height)) · \(String(format: "%.2f", source.frameRate)) fps · \(source.codec)")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Button("Reset All Edits") { model.timeline.reset() }
                .disabled(model.timeline.isUnedited)
        }
    }

    private func row(_ title: String, _ value: Double, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(formatTimecode(value)).monospacedDigit().foregroundStyle(.secondary)
            Button("Set to Playhead", action: action).controlSize(.small)
        }
    }
}

// MARK: - Stabilize

private struct StabilizePanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        PanelSection(title: "Stabilization") {
            Toggle("Stabilize video", isOn: $model.stabilization.enabled)
                .toggleStyle(.switch)
            if let progress = model.stabilizationProgress {
                VStack(alignment: .leading) {
                    Text("Analyzing camera motion…").font(.callout)
                    ProgressView(value: progress)
                    Button("Cancel") { model.cancelAnalysis() }.controlSize(.small)
                }
            } else if model.stabilizationAnalysis != nil {
                Label("Motion analyzed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            } else {
                Text("The clip is analyzed frame by frame (Vision image registration) the first time you turn this on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        PanelSection(title: "Amount") {
            LabeledSlider(title: "Smoothness", value: $model.stabilization.strength, range: 0.05...1) { v in
                v < 0.3 ? "Light" : v < 0.7 ? "Medium" : "Strong"
            }
            LabeledSlider(title: "Max crop", value: $model.stabilization.maxCrop, range: 0.02...0.25, format: percent)
            Text("Smoothness sets how long camera movements are averaged over. More smoothing needs more room: the frame is zoomed in up to the max crop to hide the moving edges.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(!model.stabilization.enabled)

        if model.stabilizationAnalysis != nil {
            Button("Re-analyze") { model.analyzeStabilization() }
                .disabled(model.stabilizationProgress != nil)
        }
    }
}

// MARK: - Filters

private struct FiltersPanel: View {
    @EnvironmentObject private var model: EditorModel
    @State private var previews: [FilterKind: CGImage] = [:]
    private static let context = CIContext()

    var body: some View {
        PanelSection(title: "Look") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                ForEach(FilterKind.allCases) { kind in
                    Button { model.filter.kind = kind } label: {
                        VStack(spacing: 4) {
                            Group {
                                if let image = previews[kind] {
                                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.secondary.opacity(0.2)
                                }
                            }
                            .frame(height: 56)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(model.filter.kind == kind ? Color.accentColor : .clear, lineWidth: 2.5))
                            Text(kind.title).font(.caption).lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            LabeledSlider(title: "Intensity", value: $model.filter.intensity, range: 0...1, format: percent)
                .disabled(model.filter.kind == .none)
        }
        .task(id: model.thumbnails.count) { makePreviews() }

        PanelSection(title: "Adjust") {
            LabeledSlider(title: "Brightness", value: $model.filter.brightness, range: -0.3...0.3)
            LabeledSlider(title: "Contrast", value: $model.filter.contrast, range: 0.6...1.6)
            LabeledSlider(title: "Saturation", value: $model.filter.saturation, range: 0...2)
            LabeledSlider(title: "Vignette", value: $model.filter.vignette, range: 0...1.5)
            Button("Reset") { model.filter = FilterSettings() }
                .disabled(model.filter == FilterSettings())
        }
    }

    private func makePreviews() {
        guard !model.thumbnails.isEmpty else { return }
        let base = CIImage(cgImage: model.thumbnails[model.thumbnails.count / 2])
        var result: [FilterKind: CGImage] = [:]
        for kind in FilterKind.allCases {
            let output = kind.apply(to: base).cropped(to: base.extent)
            result[kind] = Self.context.createCGImage(output, from: base.extent)
        }
        previews = result
    }
}

// MARK: - Audio

private struct AudioPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        PanelSection(title: "Original sound") {
            if model.source?.audioTrack == nil {
                Text("This clip has no audio.").foregroundStyle(.secondary)
            } else {
                LabeledSlider(title: "Volume", value: $model.audio.originalVolume, range: 0...1.5, format: percent)
                Toggle("Mute original sound", isOn: Binding(
                    get: { model.audio.originalVolume == 0 },
                    set: { model.audio.originalVolume = $0 ? 0 : 1 }))
            }
        }

        PanelSection(title: "Background music") {
            if let url = model.audio.musicURL {
                HStack {
                    Image(systemName: "music.note").foregroundStyle(Color.accentColor)
                    Text(url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { model.setMusic(nil) } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .help("Remove music")
                }
                LabeledSlider(title: "Volume", value: $model.audio.musicVolume, range: 0...1, format: percent)
                if model.musicDuration > 1 {
                    LabeledSlider(title: "Start music at", value: $model.audio.musicStartOffset,
                                  range: 0...max(0.1, model.musicDuration - 1)) { formatTimecode($0, fractional: false) }
                }
                Toggle("Loop to fill the video", isOn: $model.audio.loopMusic)
                LabeledSlider(title: "Fade in", value: $model.audio.fadeIn, range: 0...5) { String(format: "%.1fs", $0) }
                LabeledSlider(title: "Fade out", value: $model.audio.fadeOut, range: 0...8) { String(format: "%.1fs", $0) }
                Button("Replace…") { model.requestImport(.music) }
            } else {
                Button {
                    model.requestImport(.music)
                } label: {
                    Label("Add Music…", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Text(platformHint(mac: "MP3, M4A/AAC, WAV or AIFF. You can also drop a file on the window.",
                                  phone: "MP3, M4A/AAC, WAV or AIFF from Files."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Export

private struct ExportPanel: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        PanelSection(title: "Format") {
            Picker("Quality", selection: $model.exportPreset) {
                ForEach(ExportPreset.allCases) { Text($0.title).tag($0) }
            }
            Picker("File type", selection: $model.exportContainer) {
                ForEach(ExportContainer.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Length")
                Spacer()
                Text(formatTimecode(model.outputDuration)).monospacedDigit().foregroundStyle(.secondary)
            }
        }

        PanelSection(title: "Export") {
            if let progress = model.exportProgress {
                ProgressView(value: progress)
                Button("Cancel Export") { model.cancelExport() }
            } else {
                Button {
                    model.requestExport()
                } label: {
                    Label("Export Video…", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            if let url = model.lastExportURL {
                ExportResultView(url: url)
            }
            Text("Trim, stabilization, filters, the data overlay and the music are all rendered into the exported file.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// What to do with a finished export: reveal it on macOS, save or share it on iOS.
private struct ExportResultView: View {
    @EnvironmentObject private var model: EditorModel
    let url: URL

    var body: some View {
        #if os(macOS)
        HStack {
            Label(url.lastPathComponent, systemImage: "checkmark.circle.fill").foregroundStyle(.green).lineLimit(1)
            Spacer()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .controlSize(.small)
        }
        #else
        VStack(alignment: .leading, spacing: 10) {
            Label("Export finished", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            HStack {
                Button {
                    model.saveExportToPhotos()
                } label: {
                    Label(model.savedToPhotos ? "Saved to Photos" : "Save to Photos",
                          systemImage: model.savedToPhotos ? "checkmark" : "photo.on.rectangle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.savedToPhotos)
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered)
            }
        }
        #endif
    }
}
