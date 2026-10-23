import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// iPhone layout: preview on top, transport and timeline below it, the editing panels underneath.
struct PhoneEditorView: View {
    @EnvironmentObject private var model: EditorModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var isImportingPhoto = false

    var body: some View {
        NavigationStack {
            Group {
                if model.source == nil {
                    WelcomeView(isLoading: isImportingPhoto || model.isLoading,
                                choosePhoto: { showPhotoPicker = true },
                                chooseFile: { model.requestImport(.video) })
                } else {
                    editor
                }
            }
            .navigationTitle(model.source == nil ? "FitMovie" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.source != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            Button("From Photos", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                            Button("From Files", systemImage: "folder") { model.requestImport(.video) }
                        } label: {
                            Label("New Video", systemImage: "plus")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Export") {
                            model.inspectorTab = .export
                            model.requestExport()
                        }
                        .fontWeight(.semibold)
                        .disabled(model.exportProgress != nil)
                    }
                }
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .videos,
                      preferredItemEncoding: .current)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            loadPhoto(item)
        }
        .fileImports(for: model)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            PhonePreview()
                .frame(maxWidth: .infinity)
                .frame(height: 250)
            PhoneTransport()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            TimelineStrip()
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            Divider()
            InspectorView()
        }
    }

    private func loadPhoto(_ item: PhotosPickerItem) {
        isImportingPhoto = true
        Task {
            defer {
                isImportingPhoto = false
                photoItem = nil
            }
            do {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { return }
                model.importFile(movie.url, as: .video)
            } catch {
                model.errorMessage = "Couldn't load the video from Photos: \(error.localizedDescription)"
            }
        }
    }
}

/// A video file handed over by the photo picker, copied into the app's temporary folder.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Imported", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: destination)
            return PickedMovie(url: destination)
        }
    }
}

private struct WelcomeView: View {
    let isLoading: Bool
    let choosePhoto: () -> Void
    let chooseFile: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "film.stack")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 6) {
                Text("Edit your footage").font(.title2.weight(.semibold))
                Text("Trim, stabilize, add filters, music and your watch data from a FIT file.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            VStack(spacing: 12) {
                Button(action: choosePhoto) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: chooseFile) {
                    Label("Browse Files", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.horizontal, 40)
            .disabled(isLoading)
            if isLoading { ProgressView("Loading video…") }
            Spacer()
            Text("GoPro and DJI clips: import them to Photos or Files first.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.bottom)
        }
    }
}

private struct PhonePreview: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        ZStack {
            Color.black
            PlayerSurface(player: model.player)
            if let image = model.scrubImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
            LimitedPreviewBadge()
            if let progress = model.exportProgress {
                VStack(spacing: 10) {
                    Text("Exporting…").font(.headline)
                    ProgressView(value: progress).frame(width: 200)
                    Button("Cancel", role: .cancel) { model.cancelExport() }
                }
                .padding(20)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .clipped()
        .contentShape(Rectangle())
        .onTapGesture { model.togglePlay() }
    }
}

private struct PhoneTransport: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        HStack(spacing: 14) {
            Button { model.togglePlay() } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 30)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(formatTimecode(model.timeline.outputTime(forSource: model.currentSourceTime)))
                    .font(.system(.subheadline, design: .monospaced))
                Text(formatTimecode(model.outputDuration))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.step(frames: -1) } label: { Image(systemName: "chevron.left") }
            Button { model.step(frames: 1) } label: { Image(systemName: "chevron.right") }
            Menu {
                Button("Start Here", systemImage: "arrow.right.to.line") { model.setTrimStartToPlayhead() }
                Button("End Here", systemImage: "arrow.left.to.line") { model.setTrimEndToPlayhead() }
                Divider()
                Button("Mark In", systemImage: "chevron.left.to.line") { model.setMarkIn() }
                Button("Mark Out", systemImage: "chevron.right.to.line") { model.setMarkOut() }
            } label: {
                Image(systemName: "scissors.badge.ellipsis")
            }
            Button { model.removeSelection() } label: {
                Image(systemName: "scissors")
            }
            .disabled(!model.canRemoveSelection)
        }
        .font(.body.weight(.medium))
    }
}
