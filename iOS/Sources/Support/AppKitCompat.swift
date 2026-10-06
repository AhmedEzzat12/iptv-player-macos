import SwiftUI
import UIKit
import UniformTypeIdentifiers

// The shared app sources (../Sources/Tuner) were written for macOS. Rather than sprinkling #if through every
// view, the AppKit names they use map onto UIKit equivalents here, keeping the shared files identical for the
// Mac build. Rules:
//   • Simple renames (NSImage → UIImage) are typealiases.
//   • Mac-only concepts with no iOS meaning (window buttons, full-screen notifications, the pointer) are
//     harmless no-ops.
//   • Anything that must behave differently on iOS (file panels) is reimplemented with the iOS equivalent.
// View subclasses and event monitors are not shimmed; they have real iOS implementations in iOS/Sources.
// iOS-only code should use the UIKit names directly.

typealias NSView = UIView
typealias NSImage = UIImage
typealias NSColor = UIColor
typealias NSWindow = UIWindow
typealias NSRect = CGRect
typealias NSSize = CGSize
typealias NSPoint = CGPoint

// MARK: - Representables

/// `NSViewRepresentable` written for AppKit compiles as a `UIViewRepresentable`: the NS-named requirements are
/// forwarded. Only for shared views whose body is otherwise platform-neutral (the YouTube trailer's WKWebView).
@MainActor
protocol NSViewRepresentable: UIViewRepresentable where UIViewType == NSViewType {
    associatedtype NSViewType: UIView
    func makeNSView(context: Context) -> NSViewType
    func updateNSView(_ nsView: NSViewType, context: Context)
    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator)
}

extension NSViewRepresentable {
    func makeUIView(context: Context) -> NSViewType { makeNSView(context: context) }
    func updateUIView(_ uiView: NSViewType, context: Context) { updateNSView(uiView, context: context) }
    static func dismantleUIView(_ uiView: NSViewType, coordinator: Coordinator) { dismantleNSView(uiView, coordinator: coordinator) }
    static func dismantleNSView(_ nsView: NSViewType, coordinator: Coordinator) {}
}

// MARK: - Application and windows

/// `NSApp`: the active state and key window map onto the iOS application and its foreground scene.
@MainActor
let NSApp = NSApplicationCompat()

@MainActor
final class NSApplicationCompat {
    var isActive: Bool { UIApplication.shared.applicationState == .active }

    var keyWindow: UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .keyWindow
    }

    var mainWindow: UIWindow? { keyWindow }
}

enum NSApplication {
    enum ModalResponse { case OK, cancel }
}

extension UIWindow {
    struct StyleMask: OptionSet {
        let rawValue: Int
        static let fullScreen = StyleMask(rawValue: 1 << 14)
    }

    /// iOS apps are always "full screen"; there's no window full-screen mode to toggle.
    var styleMask: StyleMask { [] }
    func toggleFullScreen(_ sender: Any?) {}

    static let didEnterFullScreenNotification = Notification.Name("TunerCompat.windowDidEnterFullScreen")
    static let didExitFullScreenNotification = Notification.Name("TunerCompat.windowDidExitFullScreen")
}

/// Menu tracking notifications (macOS pauses the player chrome's auto-hide while a menu is open).
/// SwiftUI menus on iOS don't post them, so they never fire.
enum NSMenu {
    static let didBeginTrackingNotification = Notification.Name("TunerCompat.menuDidBeginTracking")
    static let didEndTrackingNotification = Notification.Name("TunerCompat.menuDidEndTracking")
}

/// The pointer: no cursor to hide on touch screens.
enum NSCursor {
    static func setHiddenUntilMouseMoves(_ hidden: Bool) {}
}

enum NSEvent {
    static var mouseLocation: CGPoint { .zero }
}

// MARK: - Workspace and pasteboard

/// `NSWorkspace`: opening URLs goes through the system; "Show in Finder" opens the Files app.
@MainActor
final class NSWorkspace {
    static let shared = NSWorkspace()

    /// Web links open in the browser/app; local folders and files open in the Files app.
    @discardableResult
    func open(_ url: URL) -> Bool {
        if url.isFileURL {
            guard let files = URL(string: "shareddocuments://" + url.path) else { return false }
            UIApplication.shared.open(files)
        } else {
            UIApplication.shared.open(url)
        }
        return true
    }

    /// Opens the Files app at the item's folder (works for the app's Documents, shared via UIFileSharingEnabled).
    func activateFileViewerSelecting(_ urls: [URL]) {
        guard let folder = urls.first?.deletingLastPathComponent(),
              let url = URL(string: "shareddocuments://" + folder.path) else { return }
        UIApplication.shared.open(url)
    }

    func icon(forFile path: String) -> UIImage { UIImage(systemName: "folder.fill") ?? UIImage() }
    func icon(for type: UTType) -> UIImage { UIImage(systemName: "folder.fill") ?? UIImage() }
}

/// `NSPasteboard.general` string copy → the iOS pasteboard.
@MainActor
final class NSPasteboard {
    static let general = NSPasteboard()

    enum PasteboardType { case string }

    @discardableResult
    func clearContents() -> Int { 0 }

    @discardableResult
    func setString(_ string: String, forType type: PasteboardType) -> Bool {
        UIPasteboard.general.string = string
        return true
    }

    func string(forType type: PasteboardType) -> String? { UIPasteboard.general.string }
}

// MARK: - Colors and images

/// Just enough of `NSAppearance` for `NSColor(name:dynamicProvider:)` closures that pick dark or light.
struct NSAppearance {
    struct Name: Equatable {
        fileprivate let isDark: Bool
        static let darkAqua = Name(isDark: true)
        static let aqua = Name(isDark: false)
    }

    let isDark: Bool

    func bestMatch(from names: [Name]) -> Name? { names.first { $0.isDark == isDark } }
}

extension UIColor {
    convenience init(name: String?, dynamicProvider: @escaping (NSAppearance) -> UIColor) {
        self.init { traits in dynamicProvider(NSAppearance(isDark: traits.userInterfaceStyle == .dark)) }
    }

    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    static var windowBackgroundColor: UIColor { .systemBackground }
    static var controlAccentColor: UIColor { .tintColor }
    static var controlBackgroundColor: UIColor { .secondarySystemBackground }
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
}

extension UIImage {
    /// `NSImage.cgImage(forProposedRect:context:hints:)` with every argument nil.
    func cgImage(forProposedRect rect: UnsafeMutablePointer<CGRect>?, context: Any?, hints: [String: Any]?) -> CGImage? {
        if let cgImage { return cgImage }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in draw(at: .zero) }.cgImage
    }
}

extension Color {
    init(nsColor: UIColor) { self.init(uiColor: nsColor) }
}

extension Image {
    init(nsImage: UIImage) { self.init(uiImage: nsImage) }
}

// MARK: - File panels

/// `NSOpenPanel` on top of the iOS document picker.
/// • Files are copied into the app's own storage ("Imported" in Application Support), so a playlist chosen
///   once stays readable on later syncs (a picked file's original location isn't accessible after relaunch).
/// • Folders come back security-scoped and already being accessed for this session.
@MainActor
class NSSavePanel: NSObject, UIDocumentPickerDelegate {
    var title = ""
    var message = ""
    var prompt = ""
    var nameFieldStringValue = ""
    var allowedContentTypes: [UTType] = []
    var canCreateDirectories = false
    var isExtensionHidden = false
    var directoryURL: URL?
    var url: URL?

    fileprivate var completion: ((NSApplication.ModalResponse) -> Void)?
    /// Keeps the panel alive while the picker is up (callers don't retain it).
    private static var presented: Set<NSSavePanel> = []

    func beginSheetModal(for window: UIWindow, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        begin(completionHandler: completionHandler)
    }

    /// Saving: iOS has no save panel. The file goes to the app's Documents folder, which the Files app shows
    /// under On My iPhone › Tuner (UIFileSharingEnabled).
    func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = nameFieldStringValue.isEmpty ? "Untitled" : nameFieldStringValue
        url = documents.appendingPathComponent(name)
        completionHandler(.OK)
    }

    fileprivate func present(_ picker: UIDocumentPickerViewController, completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let root = NSApp.keyWindow?.rootViewController else {
            completionHandler(.cancel)
            return
        }
        var top = root
        while let presented = top.presentedViewController { top = presented }
        completion = completionHandler
        picker.delegate = self
        Self.presented.insert(self)
        top.present(picker, animated: true)
    }

    fileprivate func finish(_ response: NSApplication.ModalResponse) {
        completion?(response)
        completion = nil
        Self.presented.remove(self)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        handlePicked(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(.cancel)
    }

    fileprivate func handlePicked(_ urls: [URL]) {
        url = urls.first
        finish(url == nil ? .cancel : .OK)
    }
}

@MainActor
final class NSOpenPanel: NSSavePanel {
    var canChooseFiles = true
    var canChooseDirectories = false
    var allowsMultipleSelection = false
    var urls: [URL] = []

    override func begin(completionHandler: @escaping (NSApplication.ModalResponse) -> Void) {
        let picker: UIDocumentPickerViewController
        if canChooseDirectories && !canChooseFiles {
            picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        } else {
            let types = allowedContentTypes.isEmpty ? [UTType.item] : allowedContentTypes
            picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        }
        picker.allowsMultipleSelection = allowsMultipleSelection
        picker.directoryURL = directoryURL
        present(picker, completionHandler: completionHandler)
    }

    override fileprivate func handlePicked(_ picked: [URL]) {
        if canChooseDirectories && !canChooseFiles {
            picked.forEach { _ = $0.startAccessingSecurityScopedResource() }
            urls = picked
        } else {
            urls = picked.compactMap(Self.keepCopy)
        }
        url = urls.first
        finish(url == nil ? .cancel : .OK)
    }

    /// Moves a picked file's temporary copy into Application Support/Tuner/Imported (replacing a same-named one).
    private static func keepCopy(_ temporary: URL) -> URL? {
        let fm = FileManager.default
        let folder = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tuner/Imported", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let target = folder.appendingPathComponent(temporary.lastPathComponent)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temporary, to: target)
            return target
        } catch {
            NSLog("Tuner: couldn't keep the picked file: \(error)")
            return temporary
        }
    }
}
