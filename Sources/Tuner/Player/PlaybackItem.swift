import Foundation
import TunerCore

/// Something the player can play.
enum PlaybackItem: Hashable, Identifiable {
    case channel(Channel)
    case catchup(Channel, Program)
    case movie(Movie)
    case episode(Episode, Series)
    case recording(Recording)

    var id: String {
        switch self {
        case .channel(let c): "ch:\(c.id)"
        case .catchup(let c, let p): "cu:\(c.id):\(Int(p.start.timeIntervalSince1970))"
        case .movie(let m): "mv:\(m.id)"
        case .episode(let e, _): "ep:\(e.id)"
        case .recording(let r): "rec:\(r.id)"
        }
    }

    /// Primary line (channel name, programme title, movie or episode title).
    var title: String {
        switch self {
        case .channel(let c): c.displayName
        case .catchup(_, let p): p.title
        case .movie(let m): m.name
        case .episode(let e, _): e.title
        case .recording(let r): r.title
        }
    }

    /// Secondary line.
    var subtitle: String? {
        switch self {
        case .channel: nil
        case .catchup(let c, let p): "\(c.displayName) · \(p.start.formatted(date: .abbreviated, time: .shortened))"
        case .movie(let m): m.year
        case .episode(let e, let s): "\(s.name) · S\(e.season), E\(e.number)"
        case .recording(let r): "\(r.channelName) · \(r.start.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    var channel: Channel? {
        switch self {
        case .channel(let c), .catchup(let c, _): c
        default: nil
        }
    }

    /// Live (never-ending) content: no scrubber, watchdog + failover enabled.
    var isLive: Bool {
        if case .channel = self { return true }
        return false
    }

    /// Key for resume progress (movies and episodes only).
    var progressKey: String? {
        switch self {
        case .movie(let m): m.id
        case .episode(let e, _): e.id
        default: nil
        }
    }

    var artworkURL: String? {
        switch self {
        case .channel(let c), .catchup(let c, _): c.logoURL
        case .movie(let m): m.backdropURL ?? m.posterURL
        case .episode(let e, let s): e.imageURL ?? s.backdropURL ?? s.coverURL
        case .recording: nil
        }
    }
}

enum MultiviewLayout: String, CaseIterable, Identifiable {
    case single
    case pictureInPicture
    case bigAndBottom
    case grid2x2

    var id: String { rawValue }
    var slotCount: Int {
        switch self {
        case .single: 1
        case .pictureInPicture: 2
        case .bigAndBottom, .grid2x2: 4
        }
    }
    var title: String {
        switch self {
        case .single: "Single"
        case .pictureInPicture: "Picture in Picture"
        case .bigAndBottom: "Main + 3"
        case .grid2x2: "2 × 2 Grid"
        }
    }
    var symbol: String {
        switch self {
        case .single: "rectangle"
        case .pictureInPicture: "pip"
        case .bigAndBottom: "rectangle.split.1x2"
        case .grid2x2: "square.grid.2x2"
        }
    }
}
