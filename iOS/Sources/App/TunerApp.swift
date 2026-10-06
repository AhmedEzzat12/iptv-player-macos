import SwiftUI
import TunerCore

/// iPhone/iPad entry point (the macOS one is Sources/Tuner/App/TunerApp.swift). Same name, so shared code that
/// reads `TunerApp.dataDirectory` works on both.
@main
struct TunerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ViewState private var model: AppModel

    /// TUNER_DATA_DIR lets development/test runs use a scratch library (and caches) instead of the user's data.
    static let dataDirectoryOverride = ProcessInfo.processInfo.environment["TUNER_DATA_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    /// Where the library and downloaded data sets live (the same folder `AppDatabase.onDisk` uses).
    static var dataDirectory: URL {
        dataDirectoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tuner", isDirectory: true)
    }

    init() {
        ImageCacheSetup.configure()
        let prefs = Preferences()
        let db: AppDatabase
        do {
            db = try AppDatabase.onDisk(directory: Self.dataDirectoryOverride)
        } catch {
            NSLog("Tuner: could not open the library database (\(error)); using a temporary one")
            db = try! AppDatabase.inMemory()
        }
        _model = ViewState(initialValue: AppModel(db: db, prefs: prefs, dataDirectory: Self.dataDirectory))
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
                .tint(model.prefs.accent.color)
                .preferredColorScheme(.dark)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            TunerCommands(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    weak var model: AppModel? {
        didSet {
            guard let model, nowPlaying == nil else { return }
            nowPlaying = NowPlayingController(model: model)
        }
    }
    private var nowPlaying: NowPlayingController?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AudioSessionSetup.configure()
        Self.configureTabNavigationBars()
        return true
    }

    /// The shared screens draw their own large headers (Home's hero, "Movies 7", the Live TV header) and set a
    /// navigation title for the Mac's window. Inside the tabs, keep that title for VoiceOver but don't draw it, and
    /// let content run under a transparent bar. Settings (a sheet, outside the tab bar controller) keeps normal titles.
    private static func configureTabNavigationBars() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.foregroundColor: UIColor.clear]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.clear]
        let bar = UINavigationBar.appearance(whenContainedInInstancesOf: [UITabBarController.self])
        bar.standardAppearance = appearance
        bar.scrollEdgeAppearance = appearance
        bar.compactAppearance = appearance
    }

    /// iPhone: portrait while browsing, the player's choice while it's full screen (see `PlayerOrientation`).
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? PlayerOrientation.mask : .all
    }

    func applicationWillTerminate(_ application: UIApplication) {
        model?.shutdown()
    }
}
