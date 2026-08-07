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

    /// The playable channel `offset` positions away from `media` within its
    /// category, honouring `sort` so the order matches the channel list the
    /// viewer browsed. `offset` is `+1` for the next channel and `-1` for the
    /// previous; the list wraps at the category's ends so surfing never
    /// dead-ends. Returns `nil` when `media` isn't a resolvable live stream or
    /// its category holds a single reachable channel.
    ///
    /// Surfing resolves against exactly the channels the browse list would show:
    /// this used to fetch the category with a hand-rolled descriptor that dropped
    /// neither channels hidden in Content Management nor categories locked away
    /// from a child profile, so a hidden channel stayed in the up/down rotation
    /// even though every list had stopped showing it. Reusing
    /// `LiveChannelQuery.descriptor` is what keeps the two in step.
    static func adjacentMedia(
        for media: PlayableMedia,
        offset: Int,
        sort: ContentSortOption,
        restriction: ContentRestriction,
        in context: ModelContext
    ) -> PlayableMedia? {
        guard case let .live(id) = media.contentRef else { return nil }
        var currentDescriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        currentDescriptor.fetchLimit = 1
        guard let current = try? context.fetch(currentDescriptor).first,
              let categoryId = current.categoryId else { return nil }

        // The shared channel-list query: same predicate (hidden channels dropped)
        // and same sort the viewer browsed with.
        let descriptor = LiveChannelQuery.descriptor(for: .category(categoryId), sort: sort)
        guard let fetched = try? context.fetch(descriptor) else { return nil }
        let streams = fetched.excludingRestricted(restriction)

        // A playing channel that isn't itself reachable — locked mid-playback, or
        // opened by deep link — has no position in the rotation, so surfing stops
        // rather than using it as a doorway into the rest of the category.
        guard streams.count > 1,
              let index = streams.firstIndex(where: { $0.id == current.id }) else { return nil }

        let target = streams[(index + offset + streams.count) % streams.count]
        guard let playlist = playlist(for: target, in: context) else { return nil }
        return PlayableMedia.from(stream: target, playlist: playlist)
    }
}
