import Foundation
import TunerCore

/// The preferences iCloud sync carries (`CloudSyncPreferences.keys`): settings that mean the same on every device.
/// Device-specific ones (engine, buffers, paths, user agents, the TMDB key, shortcuts, volume, last channel) stay here.
extension Preferences {
    func cloudSyncValues() -> [String: SyncJSON] {
        [
            "recentSearches": SyncJSON(recentSearches),
            "pinnedCategoryIds": SyncJSON(pinnedCategoryIds),
            "categoryNameStyle": .string(categoryNameStyle.rawValue),
            "hideAdultContent": .bool(hideAdultContent),
            "episodeThumbnails": .string(episodeThumbnails.rawValue),
            "autoplayNextEpisode": .bool(autoplayNextEpisode),
            "upNextCountdown": SyncJSON(upNextCountdown),
            "resumePlayback": .bool(resumePlayback),
            "metadataEnabled": .bool(metadataEnabled),
            "metadataLanguage": .string(metadataLanguage),
            "accent": .string(accent.rawValue),
            "aiGuideMatching": .bool(aiGuideMatching),
            "aiRecommendations": .bool(aiRecommendations),
            "aiNaturalLanguageSearch": .bool(aiNaturalLanguageSearch),
            "homeTopTen": .bool(homeTopTen),
            "homeTopTenRegion": .string(homeTopTenRegion),
        ]
    }

    /// Applies values from another device; unknown keys and values of the wrong type are ignored. Only real changes
    /// are assigned, so observers don't fire for nothing.
    func applyCloudSync(_ values: [String: SyncJSON]) {
        func update<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<Preferences, T>, _ value: T?) {
            if let value, self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
        }
        for (key, v) in values {
            switch key {
            case "recentSearches": update(\.recentSearches, v.strings)
            case "pinnedCategoryIds": update(\.pinnedCategoryIds, v.strings)
            case "categoryNameStyle": update(\.categoryNameStyle, v.string.flatMap(CategoryNameStyle.init(rawValue:)))
            case "hideAdultContent": update(\.hideAdultContent, v.bool)
            case "episodeThumbnails": update(\.episodeThumbnails, v.string.flatMap(EpisodeThumbnailStyle.init(rawValue:)))
            case "autoplayNextEpisode": update(\.autoplayNextEpisode, v.bool)
            case "upNextCountdown": update(\.upNextCountdown, v.int)
            case "resumePlayback": update(\.resumePlayback, v.bool)
            case "metadataEnabled": update(\.metadataEnabled, v.bool)
            case "metadataLanguage": update(\.metadataLanguage, v.string)
            case "accent": update(\.accent, v.string.flatMap(AccentTheme.init(rawValue:)))
            case "aiGuideMatching": update(\.aiGuideMatching, v.bool)
            case "aiRecommendations": update(\.aiRecommendations, v.bool)
            case "aiNaturalLanguageSearch": update(\.aiNaturalLanguageSearch, v.bool)
            case "homeTopTen": update(\.homeTopTen, v.bool)
            case "homeTopTenRegion": update(\.homeTopTenRegion, v.string)
            default: break
            }
        }
    }
}
