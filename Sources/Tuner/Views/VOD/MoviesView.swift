import SwiftUI
import TunerCore

/// Movies section: browse grid with drill-down into movie pages.
struct MoviesView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VODBrowser(kind: .movies)
                .vodDestinations()
        }
        .onChange(of: model.sectionRootRequests[.movies]) { path.removeAll() }
    }
}
