import AVFoundation
import SwiftUI

@main
struct FitMoviePhoneApp: App {
    @StateObject private var model = EditorModel()

    init() {
        // Play the preview's sound even when the ring/silent switch is on silent.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            PhoneEditorView()
                .environmentObject(model)
                // Files shared to FitMovie from other apps (a .fit from the Suunto app, a video from Files, …).
                .onOpenURL { model.importFile($0) }
        }
    }
}
