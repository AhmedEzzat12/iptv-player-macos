import SwiftUI
import TunerCore

/// Settings › AI: optional smart features. All are off until turned on, and all run on this device (nothing about
/// the library or what's watched leaves it).
struct SettingsAIPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Toggle(isOn: $prefs.aiGuideMatching) {
                    Text("Smart guide matching")
                    Text("Channels the guide doesn't list by ID get the guide channel with the closest name, ignoring tags like HD, FHD, VIP or country prefixes. A guide chosen by hand always wins.")
                }
            } header: {
                Text("Live TV")
            }

            Section {
                Toggle(isOn: $prefs.aiSmartContinueWatching) {
                    Text("Smart Continue Watching")
                    Text("Offers the next episode when you finish one, puts what you're about to finish first, and drops titles you stopped early and haven't touched in weeks.")
                }
                Toggle(isOn: $prefs.aiRecommendations) {
                    Text("Recommendations")
                    Text("“More Like This” on movie and show pages and “Because You Watched” rows on Home, worked out on this device from genres, cast, categories and plots.")
                }
                .onChange(of: prefs.aiRecommendations) { _, on in
                    // Off: free the similarity index (it's rebuilt on first use when switched back on).
                    if !on { Task { await model.recommender.clear() } }
                }
            } header: {
                Text("Movies & TV Shows")
            }

            Section {
                Toggle(isOn: $prefs.aiNaturalLanguageSearch) {
                    Text("Understand natural searches")
                    Text("Searches like “90s comedy series” or “Arabic drama movies” become filters for year, type, genre and language.")
                }
            } header: {
                Text("Search")
            } footer: {
                Text("Everything here runs on this device. Nothing about your library or what you watch is sent anywhere.")
            }
        }
        .formStyle(.grouped)
    }
}
