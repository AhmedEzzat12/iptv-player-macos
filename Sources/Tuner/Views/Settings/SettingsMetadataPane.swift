import AppKit
import SwiftUI
import TunerCore

/// Settings → Metadata: online artwork and details for movies and shows (Cinemeta by default, TMDB with
/// a key), the language for TMDB text, episode pictures, and the metadata cache.
struct SettingsMetadataPane: View {
    @Environment(AppModel.self) private var model
    /// The key being edited; saved on Return, Validate, leaving the field or closing the pane (not on every
    /// keystroke, which would re-run lookups with half-typed keys).
    @ViewState private var keyDraft = ""
    @ViewState private var revealKey = false
    @ViewState private var validation: SettingsKeyValidation = .idle
    @ViewState private var cache: SettingsCacheState = .idle
    @FocusState private var keyFocused: Bool

    private static let apiKeyPage = URL(string: "https://www.themoviedb.org/settings/api")!

    private var trimmedDraft: String { keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var prefs = model.prefs
        Form {
            Section {
                Toggle(isOn: $prefs.metadataEnabled) {
                    Text("Fetch artwork and details online")
                    Text("Backdrops, title logos, cast, ratings, trailers and episode pictures for movies and shows.")
                }
                LabeledContent {
                    Text(prefs.tmdbAPIKey.isEmpty ? "Cinemeta" : "TMDB")
                        .foregroundStyle(.secondary)
                } label: {
                    Text("Source")
                    Text(prefs.tmdbAPIKey.isEmpty
                         ? "Cinemeta is free and needs no account. Its ratings are IMDb's. Episode pictures it lacks come from TVmaze."
                         : "TMDB, with Cinemeta for anything TMDB doesn't find and TVmaze for missing episode pictures.")
                }
            } header: {
                Text("Online Metadata")
            } footer: {
                SettingsFooter("Your provider's own details always come first; online metadata fills in what's missing. When this is off, details found earlier are still shown.")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        keyField
                            .frame(minWidth: 220)
                        Button {
                            revealKey.toggle()
                        } label: {
                            Image(systemName: revealKey ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                        }
                        .buttonStyle(.borderless)
                        .help(revealKey ? "Hide Key" : "Show Key")
                        .accessibilityLabel(revealKey ? "Hide Key" : "Show Key")
                        Button("Validate", action: validate)
                            .disabled(trimmedDraft.isEmpty || validation == .checking)
                    }
                } label: {
                    Text("API key")
                    validationStatus
                }

                Picker(selection: $prefs.metadataLanguage) {
                    ForEach(SettingsMetadataLanguages.options(including: prefs.metadataLanguage), id: \.self) { code in
                        Text(SettingsMetadataLanguages.name(for: code)).tag(code)
                    }
                } label: {
                    Text("Language")
                    Text("For TMDB titles and plots. Cinemeta is in English.")
                }

                LabeledContent {
                    Link(destination: Self.apiKeyPage) {
                        Label("Get a free TMDB API key", systemImage: "arrow.up.right.square")
                    }
                } label: {
                    Text("No key yet?")
                    Text("Sign up at themoviedb.org, then copy the API key or read access token from Settings → API.")
                }
            } header: {
                Text("The Movie Database (TMDB)")
            } footer: {
                SettingsFooter("Optional. With a key, Tuner prefers TMDB: cast photos, more artwork, and titles and plots in your language. This product uses the TMDB API but is not endorsed or certified by TMDB.")
            }

            Section {
                Picker("Episode pictures", selection: $prefs.episodeThumbnails) {
                    ForEach(EpisodeThumbnailStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
            } header: {
                Text("TV Shows")
            } footer: {
                SettingsFooter("Episode pictures come from your provider, or online when it has none. “Blur unwatched episodes” keeps pictures of episodes you haven't seen blurred so they can't give anything away; once you've watched an episode, its picture shows as usual.")
            }

            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        switch cache {
                        case .clearing:
                            ProgressView().controlSize(.small)
                        case .cleared:
                            Label("Cleared", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .help("Cleared")
                        case .idle:
                            EmptyView()
                        }
                        Button("Clear Metadata Cache", action: clearCache)
                            .disabled(cache == .clearing)
                    }
                } label: {
                    Text("Cache")
                    Text("Details are kept on this Mac so pages open instantly. Clearing makes Tuner look everything up again.")
                }
            } footer: {
                SettingsFooter("Tuner looks up movies and shows by title (with the year or catalogue ID when known). Only that is sent to Cinemeta or TMDB, and a show's IMDb ID to TVmaze for episode pictures — never your playlists, account details or what you watch. Episode ratings come from IMDb's public data sets (about 64 MB, downloaded the first time you open a show and refreshed weekly). Artwork is downloaded from their image servers.")
            }
        }
        .formStyle(.grouped)
        .onAppear { keyDraft = model.prefs.tmdbAPIKey }
        .onChange(of: keyDraft) { _, _ in
            if validation != .idle, validation != .checking { validation = .idle }
        }
        .onChange(of: keyFocused) { _, focused in
            if !focused { commitKey() }
        }
        .onChange(of: prefs.metadataEnabled) { _, _ in apply() }
        .onChange(of: prefs.metadataLanguage) { _, _ in apply() }
        .onDisappear { commitKey() }
    }

    // MARK: Key

    @ViewBuilder
    private var keyField: some View {
        Group {
            if revealKey {
                TextField("API key", text: $keyDraft, prompt: Text("API key or read access token"))
                    .font(.callout.monospaced())
            } else {
                SecureField("API key", text: $keyDraft, prompt: Text("API key or read access token"))
            }
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.leading)
        .autocorrectionDisabled()
        .focused($keyFocused)
        .onSubmit(validate)
    }

    @ViewBuilder
    private var validationStatus: some View {
        switch validation {
        case .idle:
            if model.prefs.tmdbAPIKey.isEmpty {
                Text("Leave empty to use Cinemeta.")
            } else {
                Text("Saved. Validate to check it works.")
            }
        case .checking:
            Text("Checking…")
        case .valid:
            Label("The key works.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .invalid(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private func validate() {
        let key = trimmedDraft
        commitKey()
        guard !key.isEmpty else {
            validation = .idle
            return
        }
        validation = .checking
        Task {
            let message = await model.metadata.validateTMDBKey(key)
            // Ignore a result for a key that has since been edited.
            guard trimmedDraft == key else { return }
            validation = message.map(SettingsKeyValidation.invalid) ?? .valid
        }
    }

    private func commitKey() {
        let key = trimmedDraft
        guard key != model.prefs.tmdbAPIKey else { return }
        model.prefs.tmdbAPIKey = key
        apply()
    }

    private func apply() {
        Task { await model.applyPreferences() }
    }

    // MARK: Cache

    private func clearCache() {
        cache = .clearing
        Task {
            await model.metadata.clearCache()
            try? await model.db.clearIMDbRatingsCache()
            withAnimation { cache = .cleared }
            try? await Task.sleep(for: .seconds(3))
            if cache == .cleared { withAnimation { cache = .idle } }
        }
    }
}

private enum SettingsKeyValidation: Equatable {
    case idle
    case checking
    case valid
    case invalid(String)
}

private enum SettingsCacheState: Equatable {
    case idle
    case clearing
    case cleared
}

/// Languages offered for TMDB text (BCP-47), shown with their names in the user's language.
enum SettingsMetadataLanguages {
    static let common = [
        "en-US", "en-GB", "ar-SA", "ar-AE", "ar-EG", "fr-FR", "de-DE", "es-ES", "es-MX", "it-IT", "pt-BR", "pt-PT",
        "tr-TR", "nl-NL", "pl-PL", "ru-RU", "uk-UA", "sv-SE", "da-DK", "nb-NO", "fi-FI", "el-GR", "he-IL", "fa-IR",
        "hi-IN", "ur-PK", "id-ID", "ms-MY", "th-TH", "vi-VN", "zh-CN", "zh-TW", "ja-JP", "ko-KR", "ro-RO", "hu-HU",
        "cs-CZ",
    ]

    /// The common languages sorted by name (English first), plus `current` if it isn't one of them.
    static func options(including current: String) -> [String] {
        var codes = common
        if !current.isEmpty, !codes.contains(current) { codes.append(current) }
        return codes.sorted { a, b in
            if a == "en-US" || b == "en-US" { return a == "en-US" }
            return name(for: a).localizedStandardCompare(name(for: b)) == .orderedAscending
        }
    }

    /// "English (United States)"
    static func name(for code: String) -> String {
        let identifier = code.replacingOccurrences(of: "-", with: "_")
        return Locale.current.localizedString(forIdentifier: identifier) ?? code
    }
}
