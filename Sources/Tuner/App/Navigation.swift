import Foundation
import TunerCore

/// Sidebar destinations (Apple TV app–style).
enum SidebarItem: Hashable {
    case search
    case home
    case liveTV
    case movies
    case series
    case recordings
    case downloads
    case favorites
    case recent
    case group(String)

    /// Destinations that show the Live TV guide.
    var showsLiveTV: Bool {
        switch self {
        case .liveTV, .favorites, .recent, .group: true
        default: false
        }
    }
}

/// A transient in-app notification (reminders, sync results, errors).
struct Banner: Identifiable, Equatable {
    let id = UUID()
    var symbol: String
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (@MainActor () -> Void)?
    var isError = false

    static func == (lhs: Banner, rhs: Banner) -> Bool { lhs.id == rhs.id }
}

/// Request to present the source editor sheet (nil `source` = add new).
struct SourceEditorRequest: Identifiable {
    let id = UUID()
    var source: Source?
    var kind: Source.Kind
}
