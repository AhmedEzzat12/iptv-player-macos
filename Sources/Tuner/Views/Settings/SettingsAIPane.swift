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

            Section {
                Toggle(isOn: $prefs.homeTopTen) {
                    Text("Top 10 on Home")
                    Text("“Top 10 Movies” and “Top 10 TV Shows” rows with what's popular this week on Netflix (its public Top 10 lists) or in online catalogues, showing only titles your playlists have.")
                }
                if prefs.homeTopTen {
                    Picker("Chart", selection: $prefs.homeTopTenRegion) {
                        Text(automaticChartTitle).tag("")
                        Text("Netflix · Worldwide").tag("global")
                        Text("Popular now (TMDB or Cinemeta)").tag("popular")
                        Divider()
                        ForEach(TopTenText.countries, id: \.code) { country in
                            Text("Netflix · \(country.name)").tag(country.code)
                        }
                    }
                }
            } header: {
                Text("Home")
            } footer: {
                Text("Downloads public popularity lists — Netflix's weekly country list once a week (up to 30 MB, skipped on cellular and Low Data Mode), the others are small — and matches them with your library on this device. Nothing about your library is sent.")
            }
        }
        .formStyle(.grouped)
    }

    /// "Automatic (Netflix · Egypt)", or worldwide when Netflix has no list for this device's region.
    private var automaticChartTitle: String {
        let chain = TopTenRegion.automatic.chain(deviceRegion: Locale.current.region?.identifier, hasTMDBKey: false)
        if case .netflixCountry(let code) = chain.first {
            return "Automatic (Netflix · \(TopTenText.countryName(code)))"
        }
        return "Automatic (Netflix · Worldwide)"
    }
}
