//
//  LiveChannelNavigator.swift
//  Lume
//
//  Resolves the channel to surf to when the viewer asks for the next/previous
//  live stream from inside the player (the tvOS player drives this from up/down
//  on the Siri Remote). Kept as pure, cross-platform data resolution — no view
//  state — so it can be unit-tested independently of any UI.
//

import Foundation
import SwiftData

enum LiveChannelNavigator {
    /// The playlist that owns a live stream. Stream `id`s are prefixed with the
    /// owning playlist's UUID at sync time (see `ContentSyncManager`).
    static func playlist(for stream: LiveStream, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists.first { stream.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }

    /// The playable channel `offset` positions away from `media` within the list
    /// it was launched from — Favorites, Recently Watched or a category, carried
    /// on `media.channelScope` — honouring `sort` so the order matches the
    /// channel list the viewer browsed. `offset` is `+1` for the next channel
    /// and `-1` for the previous; the list wraps at its ends so surfing never
    /// dead-ends. Returns `nil` when `media` isn't a resolvable live stream or
    /// its list holds a single channel.
    static func adjacentMedia(
        for media: PlayableMedia,
        offset: Int,
        sort: ContentSortOption,
        in context: ModelContext
    ) -> PlayableMedia? {
        guard case let .live(id) = media.contentRef else { return nil }
        var currentDescriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        currentDescriptor.fetchLimit = 1
        guard let current = try? context.fetch(currentDescriptor).first,
              let playlist = playlist(for: current, in: context) else { return nil }

        let streams = surfableChannels(around: current, media: media, sort: sort, playlist: playlist, in: context)
        guard streams.count > 1,
              let index = streams.firstIndex(where: { $0.id == current.id }) else { return nil }

        let target = streams[(index + offset + streams.count) % streams.count]
        // The scope rides along so the next press surfs the same list.
        return PlayableMedia.from(stream: target, playlist: playlist, scope: media.channelScope)
    }

    /// The list `current` is surfed within: the scope playback started from,
    /// falling back to the channel's own category when there is none or the
    /// channel has since dropped out of it (un-favorited, cleared from Recently
    /// Watched). Always contains `current` when non-empty.
    private static func surfableChannels(
        around current: LiveStream,
        media: PlayableMedia,
        sort: ContentSortOption,
        playlist: Playlist,
        in context: ModelContext
    ) -> [LiveStream] {
        let prefix = "\(playlist.id.uuidString)-"
        if let scope = media.channelScope {
            let scoped = channels(in: scope, sort: sort, playlistPrefix: prefix, in: context)
            if scoped.contains(where: { $0.id == current.id }) { return scoped }
        }
        guard let categoryId = current.categoryId else { return [] }
        let category = channels(in: .category(categoryId), sort: sort, playlistPrefix: prefix, in: context)
        if category.contains(where: { $0.id == current.id }) { return category }
        // A hidden channel is in no browse list but can still be playing (recall,
        // a deep link) — surf its unfiltered category rather than dead-end.
        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: sort.liveStreamDescriptors
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// The channels a scope resolves to, using the very descriptors the browse
    /// screens query with so both surfaces stay in one order.
    private static func channels(
        in scope: LiveChannelScope,
        sort: ContentSortOption,
        playlistPrefix: String,
        in context: ModelContext
    ) -> [LiveStream] {
        let fetched = (try? context.fetch(LiveChannelQuery.descriptor(for: scope, sort: sort))) ?? []
        return LiveChannelQuery.scoped(fetched, scope: scope, playlistPrefix: playlistPrefix)
    }
}
