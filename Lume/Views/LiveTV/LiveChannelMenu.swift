//
//  LiveChannelMenu.swift
//  Lume
//
//  The secondary actions on a live channel row — long-press on iOS and tvOS,
//  right-click on macOS. One menu rather than several stacked modifiers: only
//  the outermost `contextMenu` survives on a view, so every action a channel
//  offers has to be built here.
//

import SwiftData
import SwiftUI

extension View {
    /// - Parameters:
    ///   - isFavorite: drives the favorite item's wording and glyph.
    ///   - onStartMultiView: omitted where Multi-View has no entry point.
    ///   - onRemoveFromRecents: only in the Recently Watched collection.
    func liveChannelMenu(
        isFavorite: Bool,
        onToggleFavorite: @escaping () -> Void,
        onStartMultiView: (() -> Void)? = nil,
        onRemoveFromRecents: (() -> Void)? = nil
    ) -> some View {
        contextMenu {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }

            if let onStartMultiView {
                Button(action: onStartMultiView) {
                    Label("Start Multi-View", systemImage: "rectangle.split.2x2")
                }
            }

            if let onRemoveFromRecents {
                Button(role: .destructive, action: onRemoveFromRecents) {
                    Label("Remove from Recently Watched", systemImage: "clock.badge.xmark")
                }
            }
        }
    }
}

/// Flips a channel's favorite flag. Live streams toggle the flag alone — unlike
/// movies and series, which also stamp `addedToWatchlistDate` — mirroring
/// `PlayerFavorites` and the detail screens.
enum LiveChannelFavorites {
    static func toggle(_ stream: LiveStream, in context: ModelContext) {
        stream.isFavorite.toggle()
        try? context.save()
    }
}
