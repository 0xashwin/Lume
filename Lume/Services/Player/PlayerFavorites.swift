//
//  PlayerFavorites.swift
//  Lume
//
//  Cross-platform favorite resolution + toggle for the active player media.
//  Shared by all three control overlays (the tvOS `TVPlayerControlsOverlay`,
//  and the iOS / macOS KSPlayer and VLCKit overlays) so the favorite control
//  sitting beside the audio / subtitle track menus behaves identically on
//  every engine. Series are favorited via their parent (episodes have no
//  `isFavorite` of their own). Movies and series share the one VOD favorite
//  semantic in `MediaFavorites`; live streams toggle the flag alone.
//

import Foundation
import SwiftData

enum PlayerFavorites {
    /// Whether the content behind `ref` is currently favorited.
    static func isFavorite(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Bool {
        switch ref {
        case let .episode(id):
            episode(id, in: context)?.series?.isFavorite ?? false
        case let .movie(id):
            movie(id, in: context)?.isFavorite ?? false
        case let .live(id):
            liveStream(id, in: context)?.isFavorite ?? false
        }
    }

    /// Flip the favorite state, persist, and return the new value (defaulting
    /// to the prior state if the backing model can't be resolved).
    @discardableResult
    static func toggle(for ref: PlayableMedia.ContentRef, in context: ModelContext) -> Bool {
        switch ref {
        case let .episode(id):
            guard let resolved = episode(id, in: context) else { return false }
            return MediaFavorites.toggle(resolved, in: context)
        case let .movie(id):
            guard let resolved = movie(id, in: context) else { return false }
            return MediaFavorites.toggle(resolved, in: context)
        case let .live(id):
            guard let stream = liveStream(id, in: context) else { return false }
            return LiveChannelFavorites.toggle(stream, in: context)
        }
    }

    // MARK: - Resolution

    private static func episode(_ id: String, in context: ModelContext) -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func movie(_ id: String, in context: ModelContext) -> Movie? {
        var descriptor = FetchDescriptor<Movie>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private static func liveStream(_ id: String, in context: ModelContext) -> LiveStream? {
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
