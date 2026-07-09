import Foundation
import SwiftData

/// Resolves the episode that should play after the one currently on screen, as a
/// value-type `PlayableMedia` the player can swap in directly.
///
/// Unlike the tvOS in-player rail (`TVPlayerContent.seasonEpisodes`), this looks
/// across the whole series ordered by `(season, episode)`, so the successor of a
/// season finale is the first episode of the next season — the natural "play
/// next" behaviour for both auto-advance and the on-screen Next Episode button.
/// Cross-platform: the host (`FullScreenPlayerView`) owns the lookup and hands
/// the result down to whichever engine is active.
enum NextEpisodeResolver {
    /// The next episode after `ref` as `PlayableMedia`, or `nil` when `ref` is not
    /// an episode, the series can't be resolved, this is the last episode, or no
    /// playlist can build a URL for it.
    static func nextMedia(
        after ref: PlayableMedia.ContentRef,
        in context: ModelContext,
        client: XtreamClient = XtreamClient()
    ) -> PlayableMedia? {
        guard case let .episode(id) = ref else { return nil }

        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let current = try? context.fetch(descriptor).first,
              let series = current.series else { return nil }

        // Single linear pass for the immediate successor — the smallest
        // (season, episode) strictly greater than the current one — instead of
        // sorting the whole relationship (O(n) with no allocated copy vs the old
        // O(n log n) + full sorted array). Materialising `series.episodes` once is
        // unavoidable either way; the sort and its copy were the avoidable cost.
        let currentKey = (current.seasonNum, current.episodeNum)
        var next: Episode?
        for episode in series.episodes {
            let key = (episode.seasonNum, episode.episodeNum)
            guard key > currentKey else { continue }
            if let best = next, (best.seasonNum, best.episodeNum) <= key { continue }
            next = episode
        }
        guard let next else { return nil }
        guard let playlist = playlist(for: series, in: context) else { return nil }
        return PlayableMedia.from(episode: next, playlist: playlist, client: client)
    }

    /// The playlist that owns a series, mirroring the detail screen and tvOS
    /// overlay logic: prefix-match on the playlist UUID, falling back to the
    /// first playlist.
    private static func playlist(for series: Series, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists.first { series.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }
}
