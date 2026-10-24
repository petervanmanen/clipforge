import AVKit
import SwiftUI

/// The video surface, without system controls; the apps provide their own transport and timeline.
#if os(macOS)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis = false
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
#else
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerView {
        let view = PlayerView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
#endif

/// Explains why effects aren't visible during playback when the player had to fall back to the plain edit.
struct LimitedPreviewBadge: View {
    @EnvironmentObject private var model: EditorModel

    var body: some View {
        if model.previewIsLimited && model.isPlaying {
            Label("Effects show when paused", systemImage: "info.circle")
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(false)
        }
    }
}

/// Shows the system file importer whenever the model asks for a file (`EditorModel.requestImport`).
struct FileImportHandler: ViewModifier {
    @ObservedObject var model: EditorModel
    @State private var presentedKind: ImportKind?

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: Binding(
                    get: { model.importRequest != nil },
                    set: { if !$0 { model.importRequest = nil } }),
                allowedContentTypes: model.importRequest?.contentTypes ?? [.data],
                allowsMultipleSelection: model.importRequest?.allowsMultipleSelection ?? false
            ) { result in
                guard let kind = presentedKind, case .success(let urls) = result else { return }
                model.importFiles(urls, as: kind)
            }
            .onChange(of: model.importRequest) { _, kind in
                if let kind { presentedKind = kind }
            }
    }
}

extension View {
    func fileImports(for model: EditorModel) -> some View {
        modifier(FileImportHandler(model: model))
    }
}
