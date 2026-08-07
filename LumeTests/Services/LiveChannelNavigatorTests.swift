//
//  LiveChannelNavigatorTests.swift
//  LumeTests
//
//  Covers in-player live channel resolution — the next/previous channel surfing
//  the tvOS player performs on up/down (`LiveChannelNavigator.adjacentMedia`).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

struct LiveChannelNavigatorTests {
    // Mirrors the id scheme ContentSyncManager writes:
    // "<playlistUUID>-live-<streamId>". The playlist prefix is what
    // `playlist(for:)` keys off, so tests must reproduce it.
    private func makeWorld(
        streams: [(num: Int, name: String, category: String)]
    ) throws -> (ModelContext, Playlist) {
        let container = try makeTestContainer()
        let context = ModelContext(container)
        let playlist = Playlist(
            name: "Test",
            serverURL: "http://example.com:8080",
            username: "user",
            password: "pass"
        )
        context.insert(playlist)

        for (offset, spec) in streams.enumerated() {
            let streamId = 100 + offset
            let stream = LiveStream(
                id: "\(playlist.id.uuidString)-live-\(streamId)",
                streamId: streamId,
                name: spec.name,
                num: spec.num,
                categoryId: spec.category
            )
            context.insert(stream)
        }
        try context.save()
        return (context, playlist)
    }

    private func liveRef(_ streamId: Int, _ playlist: Playlist) -> PlayableMedia.ContentRef {
        .live("\(playlist.id.uuidString)-live-\(streamId)")
    }

    private func media(
        forStreamId streamId: Int,
        playlist: Playlist,
        in context: ModelContext
    ) throws -> PlayableMedia {
        let id = "\(playlist.id.uuidString)-live-\(streamId)"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        let stream = try #require(try context.fetch(descriptor).first)
        return try #require(PlayableMedia.from(stream: stream, playlist: playlist))
    }

    private let threeChannels: [(num: Int, name: String, category: String)] = [
        (num: 1, name: "Alpha", category: "cat-a"),
        (num: 2, name: "Bravo", category: "cat-a"),
        (num: 3, name: "Charlie", category: "cat-a")
    ]

    // MARK: - Next / previous

    @Test func `next channel follows playlist order`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `previous channel follows playlist order`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let previous = LiveChannelNavigator.adjacentMedia(for: bravo, offset: -1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(previous?.contentRef == liveRef(100, playlist)) // Alpha
    }

    // MARK: - Wraparound

    @Test func `next wraps from last to first`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let charlie = try media(forStreamId: 102, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: charlie, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(100, playlist)) // Alpha
    }

    @Test func `previous wraps from first to last`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        let previous = LiveChannelNavigator.adjacentMedia(for: alpha, offset: -1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(previous?.contentRef == liveRef(102, playlist)) // Charlie
    }

    // MARK: - Sort order is honoured

    @Test func `adjacency follows the requested sort`() throws {
        // Playlist order puts Alpha first; name-descending flips it to
        // Charlie, Bravo, Alpha — so Bravo's "next" becomes Alpha.
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .nameDescending, restriction: ContentRestriction(), in: context)
        #expect(next?.contentRef == liveRef(100, playlist)) // Alpha
    }

    // MARK: - Scoping

    @Test func `adjacency stays within the same category`() throws {
        // Bravo is the lone channel in cat-b; another category's channels must
        // not leak in, so there is no neighbour to surf to.
        let (context, playlist) = try makeWorld(streams: [
            (num: 1, name: "Alpha", category: "cat-a"),
            (num: 2, name: "Bravo", category: "cat-b"),
            (num: 3, name: "Charlie", category: "cat-a")
        ])
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        let next = LiveChannelNavigator.adjacentMedia(for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context)
        #expect(next == nil)
    }

    @Test func `single channel category has no neighbour`() throws {
        let (context, playlist) = try makeWorld(streams: [
            (num: 1, name: "Alpha", category: "cat-a")
        ])
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(LiveChannelNavigator.adjacentMedia(for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context) == nil)
        #expect(LiveChannelNavigator.adjacentMedia(for: alpha, offset: -1, sort: .playlist, restriction: ContentRestriction(), in: context) == nil)
    }

    // MARK: - Non-live input

    @Test func `non-live media has no adjacent channel`() throws {
        let (context, _) = try makeWorld(streams: threeChannels)
        let movie = try #require(PlayableMedia.from(
            movie: Movie(id: "m-1", streamId: 1, name: "Film", containerExtension: "mp4"),
            playlist: Playlist(name: "P", serverURL: "http://e.com", username: "u", password: "p")
        ))

        #expect(LiveChannelNavigator.adjacentMedia(for: movie, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context) == nil)
    }

    // MARK: - Hidden channels and parental locks

    /// Hides a channel in Content Management, as the settings screen would.
    private func hide(streamId: Int, playlist: Playlist, in context: ModelContext) throws {
        let id = "\(playlist.id.uuidString)-live-\(streamId)"
        var descriptor = FetchDescriptor<LiveStream>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        try #require(try context.fetch(descriptor).first).isHidden = true
        try context.save()
    }

    @Test func `a hidden channel is skipped when surfing`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context) // Bravo
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        // Bravo is gone from every channel list, so the rocker must step over it
        // rather than tune to a channel the viewer chose to remove.
        let next = LiveChannelNavigator.adjacentMedia(
            for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
        )
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }

    @Test func `hiding all but one channel leaves nothing to surf to`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context)
        try hide(streamId: 102, playlist: playlist, in: context)
        let alpha = try media(forStreamId: 100, playlist: playlist, in: context)

        #expect(LiveChannelNavigator.adjacentMedia(
            for: alpha, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
        ) == nil)
    }

    @Test func `surfing stops when the playing channel is itself hidden`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        try hide(streamId: 101, playlist: playlist, in: context)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)

        // Bravo has no position in the rotation any more, so it can't be used as
        // a doorway into the rest of the category.
        #expect(LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: ContentRestriction(), in: context
        ) == nil)
    }

    @Test func `a child profile cannot surf within a locked category`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: ["cat-a"])

        #expect(LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: restriction, in: context
        ) == nil)
    }

    @Test func `a parent profile surfs a locked category normally`() throws {
        let (context, playlist) = try makeWorld(streams: threeChannels)
        let bravo = try media(forStreamId: 101, playlist: playlist, in: context)
        // isActive false — a lock applies only while a child profile is active.
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: ["cat-a"])

        let next = LiveChannelNavigator.adjacentMedia(
            for: bravo, offset: 1, sort: .playlist, restriction: restriction, in: context
        )
        #expect(next?.contentRef == liveRef(102, playlist)) // Charlie
    }
}
