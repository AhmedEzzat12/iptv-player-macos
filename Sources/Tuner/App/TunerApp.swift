import AppKit
import SwiftUI
import TunerCore

@main
struct TunerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model: AppModel

    init() {
        ImageCacheSetup.configure()
        let prefs = Preferences()
        let db: AppDatabase
        do {
            // TUNER_DATA_DIR lets development/test runs use a scratch library instead of the user's data.
            let override = ProcessInfo.processInfo.environment["TUNER_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            db = try AppDatabase.onDisk(directory: override)
        } catch {
            NSLog("Tuner: could not open the library database (\(error)); using a temporary one")
            db = try! AppDatabase.inMemory()
        }
        _model = ViewState(initialValue: AppModel(db: db, prefs: prefs))
    }

    var body: some Scene {
        WindowGroup("Tuner", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1360, height: 860)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { TunerCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
                .tint(model.prefs.accent.color)
                .preferredColorScheme(model.prefs.followSystemAppearance ? nil : .dark)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            guard let model, keyMonitor == nil else { return }
            keyMonitor = KeyboardShortcuts(model: model)
            nowPlaying = NowPlayingController(model: model)
        }
    }
    private var keyMonitor: KeyboardShortcuts?
    private var nowPlaying: NowPlayingController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        model?.shutdown()
    }
}
