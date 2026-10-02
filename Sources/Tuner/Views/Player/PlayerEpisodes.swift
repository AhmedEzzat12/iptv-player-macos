import SwiftUI
import TunerCore

// MARK: - Episode list inside the player

/// The show's episodes beside the video (series only): season menu, pictures, IMDb ratings, progress. Picking one
/// plays it (resuming where you left off). Opened from the player's Episodes button; Esc or ✕ closes it.
struct PlayerEpisodesPanel: View {
    @Environment(AppModel.self) private var model
    let context: AppModel.EpisodeContext
    let current: Episode

    @ViewState private var season: Int?
    @ViewState private var metadata: MediaMetadata?
    @ViewState private var progress: [String: WatchProgress] = [:]
    @ViewState private var ratings: [EpisodeRatingKey: Double] = [:]

    private var seasons: [Int] {
        let all = Set(context.episodes.map(\.season))
        // Regular seasons first, specials last (as on the show page).
        return all.filter { $0 > 0 }.sorted() + (all.contains(0) ? [0] : [])
    }

    private var shownSeason: Int { season ?? current.season }
    private var shownEpisodes: [Episode] {
        context.episodes.filter { $0.season == shownSeason }.sorted { $0.number < $1.number }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(shownEpisodes) { episode in
                            row(episode)
                                .id(episode.id)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
                .onChange(of: shownSeason) { _, _ in
                    if let first = shownEpisodes.first { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        .padding(16)
        .background(Color.black.opacity(0.35), in: shape)
        .playerGlass(in: shape)
        .foregroundStyle(.white)
        .task(id: context.series.id) { await load() }
        .task(id: model.userRevision) { progress = (try? await model.db.progress(seriesId: context.series.id)) ?? [:] }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Episodes").font(.title3.weight(.semibold))
                Text(context.series.name).font(.callout).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
            }
            Spacer(minLength: 8)
            if seasons.count > 1 {
                Menu {
                    ForEach(seasons, id: \.self) { s in
                        Button(VODFormat.seasonTitle(s)) { withAnimation(.smooth(duration: 0.25)) { season = s } }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(VODFormat.seasonTitle(shownSeason))
                        Image(systemName: "chevron.down").font(.caption.weight(.bold))
                    }
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(.white.opacity(0.14), in: Capsule())
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            Button {
                withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen = false }
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PlayerTransportButtonStyle(size: 30, iconSize: 13))
            .help("Close (Esc)")
        }
    }

    private func row(_ episode: Episode) -> some View {
        let isCurrent = episode.id == current.id
        let info = metadata?.episode(season: episode.season, number: episode.number)
        let watch = progress[episode.id]
        let watched = watch?.completed == true
        let rating = ratings[EpisodeRatingKey(season: episode.season, episode: episode.number)]
        return Button {
            withAnimation(.smooth(duration: 0.3)) { model.player.isEpisodeListOpen = false }
            guard !isCurrent else { return }
            let series = context.series
            Task { await model.play(episode: episode, in: series) }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Color.clear
                    .frame(width: 136, height: 76)
                    .overlay {
                        SeriesEpisodePicture(stillURLs: stillURLs(episode, info: info), artworkURL: artworkURL,
                                             seriesName: context.series.name, number: "E\(episode.number)",
                                             blurred: model.prefs.episodeThumbnails == .blurUnwatched && !watched && !isCurrent)
                    }
                    .overlay(alignment: .bottom) {
                        if let watch, !watch.completed, watch.position > 10 {
                            ProgressCapsule(fraction: watch.fraction, height: 3, tint: .white)
                                .padding(.horizontal, 6).padding(.bottom, 5)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if watched {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.black, .white)
                                .padding(5)
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        DownloadStatusBadge(item: model.downloadsById[episode.id], size: 18)
                            .padding(5)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    if isCurrent {
                        Text("NOW PLAYING").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(Color.accentColor)
                    }
                    Text("E\(episode.number) · \(title(episode, info: info))")
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        if let rating { IMDbRatingBadge(rating: rating) }
                        if let d = episode.durationSeconds, d > 0 { Text(Fmt.duration(Double(d))) }
                        if let air = VODEnrichment.date(episode.airDate?.nilIfEmpty ?? info?.airDate) { Text(air).lineLimit(1) }
                    }
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(isCurrent ? Color.white.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(PlayerEpisodeRowStyle())
        .help(isCurrent ? "Playing now" : "Play \(VODFormat.episodeCode(episode))")
    }

    private var artworkURL: String? {
        let s = context.series
        return s.backdropURL?.nilIfEmpty ?? metadata?.backdropURL?.nilIfEmpty ?? s.coverURL?.nilIfEmpty ?? metadata?.posterURL?.nilIfEmpty
    }

    /// Same candidates as the show page: the provider's still (unless it's just the show's artwork), the metadata
    /// still, then the fallback (TVmaze).
    private func stillURLs(_ episode: Episode, info: EpisodeMetadata?) -> [String] {
        guard model.prefs.episodeThumbnails != .hide else { return [] }
        let showArtwork = Set([context.series.coverURL, context.series.backdropURL].compactMap { $0?.nilIfEmpty })
        var urls: [String] = []
        if let own = episode.imageURL?.nilIfEmpty, !showArtwork.contains(own) { urls.append(own) }
        for url in [info?.stillURL, info?.fallbackStillURL] {
            if let url = url?.nilIfEmpty, !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    private func title(_ episode: Episode, info: EpisodeMetadata?) -> String {
        let own = episode.title.trimmingCharacters(in: .whitespaces)
        if let online = info?.title?.trimmingCharacters(in: .whitespaces).nilIfEmpty,
           own.isEmpty || own.range(of: #"s\d{1,3}\s*[\.\-_ ]?\s*e\d{1,4}|^(episode|ep\.?)\s*\d+$"#,
                                    options: [.regularExpression, .caseInsensitive]) != nil {
            return online
        }
        return own.isEmpty ? "Episode \(episode.number)" : own
    }

    private func load() async {
        let series = context.series
        metadata = await model.metadata.cachedMetadata(mediaId: series.id)
        ratings = await model.episodeRatings(for: series)
    }
}

/// "IMDb 8.6" in the IMDb badge style used on detail pages.
struct IMDbRatingBadge: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 3) {
            Text("IMDb")
                .font(.system(size: 9, weight: .heavy))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color(red: 0.96, green: 0.77, blue: 0.09), in: RoundedRectangle(cornerRadius: 3))
                .foregroundStyle(.black)
            Text(rating.formatted(.number.precision(.fractionLength(1))))
                .font(.caption.weight(.semibold))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("IMDb rating \(rating.formatted(.number.precision(.fractionLength(1))))")
    }
}

private struct PlayerEpisodeRowStyle: ButtonStyle {
    @ViewState private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.white.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.08 : 0)),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Up Next

/// Netflix-style card for the last seconds of an episode: the next episode with a countdown ring, Play Now and
/// Cancel. The ring follows the actual time left (see `UpNextCountdown`), so it pauses with the video.
struct UpNextCard: View {
    @Environment(AppModel.self) private var model
    let next: Episode
    let series: Series
    let secondsLeft: Int
    let countdown: Int

    @ViewState private var metadata: MediaMetadata?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        let info = metadata?.episode(season: next.season, number: next.number)
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 168, height: 94)
                .overlay {
                    SeriesEpisodePicture(stillURLs: stills(info), artworkURL: series.backdropURL ?? series.coverURL,
                                         seriesName: series.name, number: "E\(next.number)",
                                         blurred: model.prefs.episodeThumbnails == .blurUnwatched)
                }
                .overlay { Color.black.opacity(0.35) }
                .overlay { countdownRing }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                Text("UP NEXT").font(.caption2.weight(.bold)).tracking(0.8).foregroundStyle(.white.opacity(0.7))
                Text("\(VODFormat.episodeCode(next)) · \(info?.title?.nilIfEmpty ?? next.title)")
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(maxWidth: 220, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        model.playAdjacentEpisode(1)
                    } label: {
                        Label("Play Now", systemImage: "play.fill").font(.callout.weight(.semibold))
                    }
                    .buttonStyle(UpNextButtonStyle(prominent: true))
                    Button("Cancel") {
                        withAnimation(.smooth(duration: 0.25)) { model.cancelUpNext() }
                    }
                    .buttonStyle(UpNextButtonStyle(prominent: false))
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.4), in: shape)
        .playerGlass(in: shape)
        .foregroundStyle(.white)
        .task(id: series.id) { metadata = await model.metadata.cachedMetadata(mediaId: series.id) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Up next: \(VODFormat.episodeCode(next)), starts in \(secondsLeft) seconds")
    }

    private var countdownRing: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.25), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(secondsLeft) / CGFloat(max(countdown, 1)))
                .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.5), value: secondsLeft)
            Text("\(secondsLeft)")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
        }
        .frame(width: 46, height: 46)
    }

    private func stills(_ info: EpisodeMetadata?) -> [String] {
        guard model.prefs.episodeThumbnails != .hide else { return [] }
        return [next.imageURL, info?.stillURL, info?.fallbackStillURL].compactMap { $0?.nilIfEmpty }
    }
}

private struct UpNextButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 30)
            .foregroundStyle(prominent ? Color.black : .white)
            .background(prominent ? Color.white : Color.white.opacity(0.18), in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}
