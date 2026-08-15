//
//  MultiViewSessionTests.swift
//  LumeTests
//
//  Covers the Multi-View grid's state machine (`MultiViewSession`): the grid
//  arrangement per layout, slot identity across resizes, where the audio goes,
//  and the playlist-in-use bookkeeping the channel picker warns from.
//

import Foundation
@testable import Lume
import Testing

struct MultiViewSessionTests {
    // MARK: - Fixtures

    /// Mirrors the id scheme `ContentSyncManager` writes onto live streams:
    /// "<playlistUUID>-live-<streamId>". `MultiViewSession.playlistID(of:)`
    /// reads the playlist back out of that prefix.
    private func channel(_ streamID: Int, playlist: UUID = UUID()) -> PlayableMedia {
        let id = "\(playlist.uuidString)-live-\(streamID)"
        return PlayableMedia(
            id: "live-\(id)",
            url: URL(string: "http://example.com/live/\(streamID).ts")!,
            title: "Channel \(streamID)",
            subtitle: nil,
            posterURL: nil,
            kind: .live,
            startTime: 0,
            contentRef: .live(id)
        )
    }

    // MARK: - Layout

    @Test func `two tiles sit side by side in landscape and stack in portrait`() {
        #expect(MultiViewLayout.two.rows(isPortrait: false) == [[0, 1]])
        #expect(MultiViewLayout.two.rows(isPortrait: true) == [[0], [1]])
    }

    @Test func `three tiles put the odd one on its own full-width row`() {
        #expect(MultiViewLayout.three.rows(isPortrait: false) == [[0, 1], [2]])
        #expect(MultiViewLayout.three.rows(isPortrait: true) == [[0], [1], [2]])
    }

    @Test func `four tiles stay a two by two grid in both orientations`() {
        #expect(MultiViewLayout.four.rows(isPortrait: false) == [[0, 1], [2, 3]])
        #expect(MultiViewLayout.four.rows(isPortrait: true) == [[0, 1], [2, 3]])
    }

    @Test func `every layout lays out exactly its slot count once`() {
        for layout in MultiViewLayout.allCases {
            for isPortrait in [true, false] {
                let indices = layout.rows(isPortrait: isPortrait).flatMap(\.self)
                #expect(indices.sorted() == Array(0 ..< layout.slotCount))
            }
        }
    }

    @Test func `only the grid's top row has nothing above it`() {
        // Landscape, which is the only arrangement tvOS ever shows.
        #expect(MultiViewLayout.two.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.two.isInTopRow(1, isPortrait: false))

        #expect(MultiViewLayout.three.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.three.isInTopRow(1, isPortrait: false))
        #expect(!MultiViewLayout.three.isInTopRow(2, isPortrait: false))

        #expect(MultiViewLayout.four.isInTopRow(0, isPortrait: false))
        #expect(MultiViewLayout.four.isInTopRow(1, isPortrait: false))
        #expect(!MultiViewLayout.four.isInTopRow(2, isPortrait: false))
        #expect(!MultiViewLayout.four.isInTopRow(3, isPortrait: false))
    }

    @Test func `a stacked grid puts only its first tile on the top row`() {
        #expect(MultiViewLayout.two.isInTopRow(0, isPortrait: true))
        #expect(!MultiViewLayout.two.isInTopRow(1, isPortrait: true))
        #expect(MultiViewLayout.three.isInTopRow(0, isPortrait: true))
        #expect(!MultiViewLayout.three.isInTopRow(1, isPortrait: true))
    }

    @Test func `the smallest layout that fits a seed is chosen`() {
        #expect(MultiViewLayout.fitting(0) == .two)
        #expect(MultiViewLayout.fitting(1) == .two)
        #expect(MultiViewLayout.fitting(2) == .two)
        #expect(MultiViewLayout.fitting(3) == .three)
        #expect(MultiViewLayout.fitting(4) == .four)
        // A seed larger than the grid can't widen it past four tiles.
        #expect(MultiViewLayout.fitting(9) == .four)
    }

    // MARK: - Launch

    @Test func `a launch carries the channels the grid should open with`() {
        let launch = MultiViewLaunch(seed: [channel(1)])
        #expect(launch.seed.map(\.title) == ["Channel 1"])
        #expect(MultiViewLaunch().seed.isEmpty)
    }

    @Test func `every launch is its own identity`() {
        // The hosts present on this value and key the screen to its id, so two
        // launches must never look like the same one — a reused identity keeps
        // the previous session alive and drops the new seed.
        let first = MultiViewLaunch(seed: [channel(1)])
        let second = MultiViewLaunch(seed: [channel(1)])
        #expect(first.id != second.id)
    }

    // MARK: - Seeding

    @Test func `a session seeds its leading tiles and leaves the rest empty`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .four)
        #expect(session.slots.count == 4)
        #expect(session.slots[0].media?.title == "Channel 1")
        #expect(session.slots.dropFirst().allSatisfy { $0.media == nil })
        #expect(session.activeMedia.count == 1)
    }

    @Test func `the first seeded tile carries the audio`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        #expect(session.isAudioSlot(session.slots[0].id))
        #expect(!session.isAudioSlot(session.slots[1].id))
    }

    // MARK: - Audio

    @Test func `the first channel added takes the audio`() {
        let session = MultiViewSession()
        // Fill the *second* tile: the audio should follow the only thing playing,
        // not stay pinned to tile one.
        session.setMedia(channel(1), in: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `a later channel does not steal the audio`() {
        let session = MultiViewSession()
        session.setMedia(channel(1), in: session.slots[0].id)
        session.setMedia(channel(2), in: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    @Test func `the audio moves to a tile that is playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        session.focusAudio(on: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `an empty tile cannot take the audio`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .two)
        session.focusAudio(on: session.slots[1].id)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    @Test func `clearing the audible tile hands the audio to one still playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        session.setMedia(nil, in: session.slots[0].id)
        #expect(session.isAudioSlot(session.slots[1].id))
    }

    @Test func `clearing the last channel leaves the audio on that tile`() {
        let session = MultiViewSession(seed: [channel(1)], layout: .two)
        let first = session.slots[0].id
        session.setMedia(nil, in: first)
        #expect(session.isAudioSlot(first))
        #expect(session.activeMedia.isEmpty)
    }

    // MARK: - Resizing

    @Test func `growing the grid keeps the tiles that were already playing`() {
        let session = MultiViewSession(seed: [channel(1), channel(2)], layout: .two)
        let originalIDs = session.slots.map(\.id)
        session.layout = .four
        #expect(session.slots.count == 4)
        // Identity must survive, or SwiftUI would tear down a running player.
        #expect(Array(session.slots.prefix(2).map(\.id)) == originalIDs)
        #expect(session.activeMedia.count == 2)
    }

    @Test func `shrinking the grid drops the trailing tiles`() {
        let session = MultiViewSession(seed: [channel(1), channel(2), channel(3), channel(4)], layout: .four)
        let keptIDs = Array(session.slots.prefix(2).map(\.id))
        session.layout = .two
        #expect(session.slots.map(\.id) == keptIDs)
        #expect(session.activeMedia.map(\.title) == ["Channel 1", "Channel 2"])
    }

    @Test func `shrinking away the audible tile hands the audio to a survivor`() {
        let session = MultiViewSession(seed: [channel(1), channel(2), channel(3)], layout: .three)
        session.focusAudio(on: session.slots[2].id)
        session.layout = .two
        #expect(session.slots.count == 2)
        #expect(session.isAudioSlot(session.slots[0].id))
    }

    // MARK: - Picker bookkeeping

    @Test func `channels on screen are reported so the picker can mark them`() {
        let first = channel(1)
        let session = MultiViewSession(seed: [first], layout: .two)
        #expect(session.usedMediaIDs == [first.id])
    }

    @Test func `the playlist behind a live stream is read from its id prefix`() throws {
        let playlist = UUID()
        let resolved = try #require(MultiViewSession.playlistID(of: channel(7, playlist: playlist)))
        #expect(resolved == playlist)
    }

    @Test func `playlists feeding other tiles are reported, excluding the tile being changed`() {
        let playlistA = UUID()
        let playlistB = UUID()
        let session = MultiViewSession(
            seed: [channel(1, playlist: playlistA), channel(2, playlist: playlistB)],
            layout: .two
        )
        #expect(session.playlistsInUse() == [playlistA, playlistB])
        // Re-picking tile one must not warn about tile one's own playlist.
        #expect(session.playlistsInUse(excluding: session.slots[0].id) == [playlistB])
    }

    @Test func `two tiles on one playlist report it once`() {
        let playlist = UUID()
        let session = MultiViewSession(
            seed: [channel(1, playlist: playlist), channel(2, playlist: playlist)],
            layout: .two
        )
        #expect(session.playlistsInUse() == [playlist])
    }
}
