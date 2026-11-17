package app.tuner.tv.ui

import app.tuner.core.models.Channel
import app.tuner.core.models.Episode
import app.tuner.core.models.Movie
import app.tuner.core.models.Program
import app.tuner.core.models.Series

/** Something the player can play (port of Sources/Tuner/Player/PlaybackItem.swift). */
sealed class PlaybackItem {
    /** `list` is the channel list it was opened from, for channel up/down. */
    data class Live(val channel: Channel, val list: List<Channel>) : PlaybackItem()
    data class Catchup(val channel: Channel, val program: Program) : PlaybackItem()
    data class MovieItem(val movie: Movie, val startAt: Double? = null) : PlaybackItem()
    data class EpisodeItem(val episode: Episode, val series: Series, val episodes: List<Episode>, val startAt: Double? = null) : PlaybackItem()

    val title: String get() = when (this) {
        is Live -> channel.displayName
        is Catchup -> program.title
        is MovieItem -> movie.name
        is EpisodeItem -> episode.title
    }

    val subtitle: String? get() = when (this) {
        is Live -> channel.number?.let { "Channel $it" }
        is Catchup -> "${channel.displayName} · Catchup"
        is MovieItem -> movie.year
        is EpisodeItem -> "${series.name} · S${episode.season}, E${episode.number}"
    }
}
