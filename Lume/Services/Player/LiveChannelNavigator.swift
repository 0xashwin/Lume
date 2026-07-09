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

/// Stateful channel-surf helper held in each engine view's `@State`. Caches the
/// ordered channel ids for the current category + sort so an up/down press steps
/// an in-memory list plus one indexed fetch for the target, instead of fetching
/// and sorting the whole category (faulting every channel) on every press. The
/// order is rebuilt only when the sort changes or the current channel leaves the
/// cached set (a jump to another category via the browser or recall). Mutating
/// its fields never invalidates the view — it's a reference type in `@State`.
final class LiveChannelSurfer {
    private var sortRaw: String?
    private var ids: [String] = []

    func adjacentMedia(
        for media: PlayableMedia,
        offset: Int,
        sort: ContentSortOption,
        in context: ModelContext
    ) -> PlayableMedia? {
        guard case let .live(currentId) = media.contentRef else { return nil }
        if sortRaw != sort.rawValue || !ids.contains(currentId) {
            guard let ordered = LiveChannelNavigator.orderedChannelIds(
                forStreamId: currentId, sort: sort, in: context
            ) else { return nil }
            sortRaw = sort.rawValue
            ids = ordered.ids
        }
        guard let index = ids.firstIndex(of: currentId), ids.count > 1 else { return nil }
        let targetId = ids[(index + offset + ids.count) % ids.count]
        return LiveChannelNavigator.media(forStreamId: targetId, in: context)
    }
}

enum LiveChannelNavigator {
    /// The playlist that owns a live stream. Stream `id`s are prefixed with the
    /// owning playlist's UUID at sync time (see `ContentSyncManager`).
    static func playlist(for stream: LiveStream, in context: ModelContext) -> Playlist? {
        let playlists = (try? context.fetch(FetchDescriptor<Playlist>())) ?? []
        return playlists.first { stream.id.hasPrefix($0.id.uuidString) } ?? playlists.first
    }

    /// The ordered live-stream `id`s in the same category as `streamId`,
    /// honouring `sort` so the order matches the browsed channel list, plus that
    /// category id. Callers cache this and step it in memory so channel surfing
    /// no longer re-fetches and re-sorts the whole category (faulting every
    /// channel) on each up/down press — the fetch runs once per category instead.
    static func orderedChannelIds(
        forStreamId streamId: String,
        sort: ContentSortOption,
        in context: ModelContext
    ) -> (categoryId: String, ids: [String])? {
        var currentDescriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == streamId })
        currentDescriptor.fetchLimit = 1
        guard let current = try? context.fetch(currentDescriptor).first,
              let categoryId = current.categoryId else { return nil }

        let descriptor = FetchDescriptor<LiveStream>(
            predicate: #Predicate { $0.categoryId == categoryId },
            sortBy: sort.liveStreamDescriptors
        )
        guard let streams = try? context.fetch(descriptor), streams.count > 1 else { return nil }
        return (categoryId, streams.map(\.id))
    }

    /// The playable channel with `id`, or `nil` when it can't be resolved. A
    /// single indexed fetch — used to build the target `PlayableMedia` after the
    /// caller has stepped its cached channel order.
    static func media(forStreamId id: String, in context: ModelContext) -> PlayableMedia? {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let stream = try? context.fetch(descriptor).first,
              let playlist = playlist(for: stream, in: context) else { return nil }
        return PlayableMedia.from(stream: stream, playlist: playlist)
    }
}
