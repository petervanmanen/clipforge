import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var model: EditorModel
    @State private var showInspector = true
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if model.source == nil {
                EmptyStateView(isLoading: model.isLoading, isDropTargeted: isDropTargeted)
            } else {
                VStack(spacing: 0) {
                    PreviewArea()
                    Divider()
                    TransportBar()
                    TimelineStrip()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                }
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .inspector(isPresented: $showInspector) {
            InspectorView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
                .disabled(model.source == nil)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.requestImport(.video) } label: { Label("Open", systemImage: "folder") }
                    .help("Open a video (⌘O)")
                Button { model.requestExport() } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(model.source == nil || model.exportProgress != nil)
                    .help("Export the edited video (⌘E)")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .navigationTitle(model.source?.url.lastPathComponent ?? "FitMovie")
        .fileImports(for: model)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        urls.append(url)
                    } else if let data = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data,
                              let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                model.handleDrop(urls)
            }
            return true
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct EmptyStateView: View {
    @EnvironmentObject private var model: EditorModel
    let isLoading: Bool
    let isDropTargeted: Bool

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "film.stack")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Drop a video here")
                .font(.title2.weight(.semibold))
            Text("iPhone, GoPro, DJI and Android footage (MOV, MP4, HEVC, H.264)")
                .foregroundStyle(.secondary)
            Button("Open Video…") { model.requestImport(.video) }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            if isLoading { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                .padding(24)
        }
    }
}

// MARK: - Preview

private struct PreviewArea: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: model.player)
            if let image = model.scrubImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            }
            LimitedPreviewBadge()
            if let progress = model.exportProgress {
                ExportOverlay(progress: progress)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct ExportOverlay: View {
    @EnvironmentObject private var model: EditorModel
    let progress: Double

    var body: some View {
        VStack(spacing: 12) {
            Text("Exporting…").font(.headline)
            ProgressView(value: progress).frame(width: 260)
            Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            Button("Cancel") { model.cancelExport() }
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Transport

private struct TransportBar: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { model.jumpToStart() } label: { Image(systemName: "backward.end.fill") }
                    .help("Go to start")
                Button { model.step(frames: -1) } label: { Image(systemName: "chevron.left") }
                    .keyboardShortcut(",", modifiers: [])
                    .help("Previous frame ( , )")
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play / pause (space)")
                Button { model.step(frames: 1) } label: { Image(systemName: "chevron.right") }
                    .keyboardShortcut(".", modifiers: [])
                    .help("Next frame ( . )")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 1) {
                Text(formatTimecode(model.timeline.outputTime(forSource: model.currentSourceTime)))
                    .font(.system(.body, design: .monospaced))
                Text("of \(formatTimecode(model.outputDuration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 6) {
                Button("Start", systemImage: "arrow.right.to.line") { model.setTrimStartToPlayhead() }
                    .keyboardShortcut("[", modifiers: [])
                    .help("Trim start to playhead ( [ )")
                Button("End", systemImage: "arrow.left.to.line") { model.setTrimEndToPlayhead() }
                    .keyboardShortcut("]", modifiers: [])
                    .help("Trim end to playhead ( ] )")
                Divider().frame(height: 18)
                Button("In", systemImage: "chevron.left.to.line") { model.setMarkIn() }
                    .keyboardShortcut("i", modifiers: [])
                    .help("Mark the start of a part to remove ( I )")
                Button("Out", systemImage: "chevron.right.to.line") { model.setMarkOut() }
                    .keyboardShortcut("o", modifiers: [])
                    .help("Mark the end of a part to remove ( O )")
                Button("Remove", systemImage: "scissors") { model.removeSelection() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(!model.canRemoveSelection)
                    .help("Remove the marked part (⌫)")
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
