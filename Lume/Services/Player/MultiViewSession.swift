//
//  MultiViewSession.swift
//  Lume
//
//  State behind Multi-View: the live channels playing at once, which tile
//  carries the audio, and how the grid is arranged. Deliberately free of any
//  view code so the grid arithmetic and slot bookkeeping are unit-testable.
//

import Foundation

// MARK: - Layout

/// How many tiles the Multi-View grid holds, and how they are arranged.
enum MultiViewLayout: Int, CaseIterable, Identifiable {
    case two = 2
    case three = 3
    case four = 4

    var id: Int {
        rawValue
    }

    /// Tiles this layout holds.
    var slotCount: Int {
        rawValue
    }

    var systemImage: String {
        switch self {
        case .two: "rectangle.split.2x1"
        case .three: "rectangle.split.3x1"
        case .four: "rectangle.split.2x2"
        }
    }

    var title: LocalizedStringResource {
        switch self {
        case .two: "2 Streams"
        case .three: "3 Streams"
        case .four: "4 Streams"
        }
    }

    /// Row-major slot indices for the grid. A tall container stacks the two- and
    /// three-tile grids vertically so each tile keeps a usable width; four tiles
    /// stay a 2×2 either way, since a four-high column leaves nothing readable.
    func rows(isPortrait: Bool) -> [[Int]] {
        switch self {
        case .two:
            isPortrait ? [[0], [1]] : [[0, 1]]
        case .three:
            isPortrait ? [[0], [1], [2]] : [[0, 1], [2]]
        case .four:
            [[0, 1], [2, 3]]
        }
    }

    /// Whether `index` sits in the grid's top row — the only slots with nothing
    /// above them. A press up from anywhere else has a tile to move to, so only
    /// these should summon the controls.
    func isInTopRow(_ index: Int, isPortrait: Bool) -> Bool {
        rows(isPortrait: isPortrait).first?.contains(index) ?? false
    }

    static let storageKey = "lume.multiView.layout"

    /// The smallest layout that holds `count` streams, so opening Multi-View
    /// with a seed never drops one on the floor.
    static func fitting(_ count: Int) -> MultiViewLayout {
        switch count {
        case ...2: .two
        case 3: .three
        default: .four
        }
    }
}

// MARK: - Slot

/// One tile in the Multi-View grid. The identity is a `UUID` rather than the
/// grid position: a tile must keep its live player when a *sibling* tile is
/// filled, cleared, or dropped by a layout change, and position-based identity
/// would tear the wrong player down.
struct MultiViewSlot: Identifiable, Hashable {
    let id = UUID()
    var media: PlayableMedia?
}

// MARK: - Launch

/// One request to open Multi-View, carrying the channels it should start with.
///
/// The seed travels *with* the presentation rather than beside it: a separate
/// "is presented" flag and seed property are two independent pieces of state, and
/// the presentation can be built from the flag before the seed lands — which
/// opened the grid empty when Multi-View was started from a channel. Presenting
/// on this value instead makes that impossible, and its fresh `id` per launch
/// gives the screen a new identity so its `@State` session is rebuilt.
struct MultiViewLaunch: Identifiable {
    let id = UUID()
    var seed: [PlayableMedia] = []
}

#if os(macOS)
    /// Channels waiting for the Multi-View window to pick them up. macOS opens a
    /// single, long-lived window rather than presenting a screen, so there is no
    /// launch value to build it from — the grid takes what is queued here when it
    /// appears, and the window may already be open, in which case the channels
    /// fill its free tiles.
    @Observable
    final class MultiViewLaunchQueue {
        static let shared = MultiViewLaunchQueue()

        var pending: [PlayableMedia] = []

        private init() {}

        /// Returns the queued channels and empties the queue, so a later open
        /// from the toolbar starts blank.
        func take() -> [PlayableMedia] {
            defer { pending = [] }
            return pending
        }
    }
#endif

// MARK: - Session

/// The live Multi-View grid. Owned by `MultiViewScreen` for the lifetime of the
/// screen — nothing here is persisted beyond the chosen layout.
@Observable
final class MultiViewSession {
    /// The grid's tiles in row-major order. Always `layout.slotCount` long.
    private(set) var slots: [MultiViewSlot]

    /// The tile whose audio is heard. Every other tile plays muted: streams from
    /// different providers are never time-aligned, so more than one audible at
    /// once is just noise.
    private(set) var audioSlotID: MultiViewSlot.ID

    var layout: MultiViewLayout {
        didSet { resize() }
    }

    init(seed: [PlayableMedia] = [], layout: MultiViewLayout = .two) {
        self.layout = layout
        let initial = (0 ..< layout.slotCount).map { index in
            MultiViewSlot(media: index < seed.count ? seed[index] : nil)
        }
        slots = initial
        // Seeded or not, slot 0 exists (the smallest layout holds two tiles).
        audioSlotID = initial[0].id
    }

    /// Channels currently playing, in grid order.
    var activeMedia: [PlayableMedia] {
        slots.compactMap(\.media)
    }

    /// Channel ids on screen, so the picker can mark what is already playing.
    var usedMediaIDs: Set<String> {
        Set(activeMedia.map(\.id))
    }

    func isAudioSlot(_ slotID: MultiViewSlot.ID) -> Bool {
        slotID == audioSlotID
    }

    /// Move the audio to `slotID`. Ignored for an empty tile: there would be
    /// nothing to hear, and the tile that *was* audible would go silent for no
    /// reason.
    func focusAudio(on slotID: MultiViewSlot.ID) {
        guard slots.first(where: { $0.id == slotID })?.media != nil else { return }
        audioSlotID = slotID
    }

    /// Put `media` in a tile — or clear it with `nil`. The tile takes the audio
    /// when nothing audible is playing, so the first channel added is always the
    /// one you hear; clearing the audible tile hands the audio to another tile
    /// that is still playing.
    func setMedia(_ media: PlayableMedia?, in slotID: MultiViewSlot.ID) {
        guard let index = slots.firstIndex(where: { $0.id == slotID }) else { return }
        slots[index].media = media
        if media != nil, audioSlotMedia == nil {
            audioSlotID = slotID
        } else if media == nil, audioSlotID == slotID {
            audioSlotID = slots.first { $0.media != nil }?.id ?? slotID
        }
    }

    /// Playlists already feeding a tile, ignoring `slotID` (the tile about to be
    /// changed). Providers commonly allow a single concurrent connection per
    /// account, so the picker warns before a second tile is pointed at a
    /// playlist that is already streaming.
    func playlistsInUse(excluding slotID: MultiViewSlot.ID? = nil) -> Set<UUID> {
        var inUse: Set<UUID> = []
        for slot in slots where slot.id != slotID {
            if let media = slot.media, let playlistID = Self.playlistID(of: media) {
                inUse.insert(playlistID)
            }
        }
        return inUse
    }

    /// The playlist a live stream belongs to, read from the playlist-UUID prefix
    /// `ContentSyncManager` stamps onto every synced stream id.
    static func playlistID(of media: PlayableMedia) -> UUID? {
        guard case let .live(streamID) = media.contentRef else { return nil }
        return UUID(uuidString: String(streamID.prefix(36)))
    }

    private var audioSlotMedia: PlayableMedia? {
        slots.first { $0.id == audioSlotID }?.media
    }

    /// Grow or shrink the grid to the current layout, keeping the tiles — and so
    /// the live players — that survive. Dropping the tile that held the audio
    /// hands it to the first tile still playing.
    private func resize() {
        let target = layout.slotCount
        if slots.count < target {
            slots.append(contentsOf: (slots.count ..< target).map { _ in MultiViewSlot() })
        } else if slots.count > target {
            slots.removeLast(slots.count - target)
        }
        guard !slots.contains(where: { $0.id == audioSlotID }) else { return }
        audioSlotID = slots.first { $0.media != nil }?.id ?? slots[0].id
    }
}
