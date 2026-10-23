import SwiftUI

@main
struct ClipForgeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = EditorModel()

    var body: some Scene {
        Window("ClipForge", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 640)
                .onAppear { appDelegate.openHandler = { model.handleDrop($0) } }
        }
        .defaultSize(width: 1360, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { model.openVideoPanel() }
                    .keyboardShortcut("o")
                Button("Load FIT File…") { model.loadFITPanel() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.source == nil)
                Button("Add Background Music…") { model.chooseMusicPanel() }
                    .disabled(model.source == nil)
                Divider()
                Button("Export…") { model.exportPanel() }
                    .keyboardShortcut("e")
                    .disabled(model.source == nil || model.exportProgress != nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files opened from Finder ("Open With", Dock icon) before the window exists are queued.
    private var pendingURLs: [URL] = []
    var openHandler: (([URL]) -> Void)? {
        didSet {
            if let openHandler, !pendingURLs.isEmpty {
                openHandler(pendingURLs)
                pendingURLs = []
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let openHandler { openHandler(urls) } else { pendingURLs += urls }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched from `swift run` (no bundle) so the window gets focus and a menu bar.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
