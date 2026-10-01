import SwiftUI
import TunerCore

/// Movies section: browse grid with drill-down into movie pages.
struct MoviesView: View {
    @ViewState private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VODBrowser(kind: .movies)
                .vodDestinations()
        }
    }
}
