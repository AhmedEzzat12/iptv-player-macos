import SwiftUI
import TunerCore

/// TV Shows section: browse grid with drill-down into show pages.
struct SeriesView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var path: [VODRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            VODBrowser(kind: .series)
                .vodDestinations()
        }
        .onChange(of: model.sectionRootRequests[.series]) { path.removeAll() }
    }
}
