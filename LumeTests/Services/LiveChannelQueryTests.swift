//
//  LiveChannelQueryTests.swift
//  LumeTests
//
//  Covers the shared scoping helpers every Live TV channel list and category
//  rail funnels through. The parental filter lives here rather than in each
//  view precisely so it can be tested once and cannot be forgotten by a new
//  surface — the tvOS channel list, the in-player browser and the EPG guide all
//  shipped without it while the iOS list had it.
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct LiveChannelQueryTests {
    /// An in-memory catalog so the models under test are real `LiveStream` /
    /// `Category` instances rather than stand-ins — the helpers read `id`,
    /// `categoryId` and `isHidden` off the models themselves.
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        return try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    private func stream(_ suffix: String, playlist: UUID, category: String?) -> LiveStream {
        LiveStream(id: "\(playlist.uuidString)-live-\(suffix)", streamId: 1, name: "Ch \(suffix)", categoryId: category)
    }

    // MARK: - scoped

    @Test func `favorites scope drops channels in a locked category`() {
        let pid = UUID()
        let prefix = "\(pid.uuidString)-"
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [
            stream("1", playlist: pid, category: locked),
            stream("2", playlist: pid, category: "\(pid.uuidString)-live-open")
        ]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        let kept = LiveChannelQuery.scoped(streams, scope: .favorites, playlistPrefix: prefix, restriction: restriction)

        // A channel favorited *before* its category was locked is exactly the
        // case the virtual collections leak, since they cut across categories.
        #expect(kept.map(\.name) == ["Ch 2"])
    }

    @Test func `recently watched scope drops channels in a locked category`() {
        let pid = UUID()
        let prefix = "\(pid.uuidString)-"
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [stream("1", playlist: pid, category: locked)]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        let kept = LiveChannelQuery.scoped(streams, scope: .recentlyWatched, playlistPrefix: prefix, restriction: restriction)
        #expect(kept.isEmpty)
    }

    @Test func `a parent profile keeps every channel`() {
        let pid = UUID()
        let prefix = "\(pid.uuidString)-"
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [
            stream("1", playlist: pid, category: locked),
            stream("2", playlist: pid, category: "\(pid.uuidString)-live-open")
        ]
        // isActive false — restriction applies only while a child profile is on.
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: [locked])

        let kept = LiveChannelQuery.scoped(streams, scope: .favorites, playlistPrefix: prefix, restriction: restriction)
        #expect(kept.count == 2)
    }

    @Test func `virtual scopes still isolate the active playlist`() {
        let mine = UUID()
        let other = UUID()
        let streams = [
            stream("1", playlist: mine, category: nil),
            stream("2", playlist: other, category: nil)
        ]

        let kept = LiveChannelQuery.scoped(
            streams, scope: .favorites, playlistPrefix: "\(mine.uuidString)-", restriction: ContentRestriction()
        )
        #expect(kept.map(\.name) == ["Ch 1"])
    }

    @Test func `category scope is not playlist-filtered but is still restriction-filtered`() {
        let pid = UUID()
        let locked = "\(pid.uuidString)-live-locked"
        let streams = [stream("1", playlist: pid, category: locked)]
        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked])

        // Category ids are already playlist-prefixed, so the scope skips the
        // prefix filter — but a locked category must still never render.
        let kept = LiveChannelQuery.scoped(
            streams, scope: .category(locked), playlistPrefix: "", restriction: restriction
        )
        #expect(kept.isEmpty)
    }

    // MARK: - visibleCategories

    @Test func `visible categories drop hidden, locked and other playlists`() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "Mine", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)
        let prefix = "\(playlist.id.uuidString)-"

        let open = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: playlist)
        let hidden = Lume.Category(apiId: "2", name: "Shopping", parentId: 0, type: .live, playlist: playlist)
        hidden.isHidden = true
        let locked = Lume.Category(apiId: "3", name: "Adults", parentId: 0, type: .live, playlist: playlist)
        locked.isRestricted = true

        let otherPlaylist = Playlist(name: "Theirs", serverURL: "http://y", username: "u", password: "p")
        ctx.insert(otherPlaylist)
        let foreign = Lume.Category(apiId: "1", name: "News", parentId: 0, type: .live, playlist: otherPlaylist)
        for category in [open, hidden, locked, foreign] {
            ctx.insert(category)
        }
        try ctx.save()

        let restriction = ContentRestriction(isActive: true, restrictedCategoryIDs: [locked.id])
        let visible = LiveChannelQuery.visibleCategories(
            [open, hidden, locked, foreign], playlistPrefix: prefix, restriction: restriction
        )

        #expect(visible.map(\.id) == [open.id])
    }

    @Test func `a parent profile still sees a locked category but never a hidden one`() throws {
        let container = try makeContainer()
        let ctx = container.mainContext
        let playlist = Playlist(name: "Mine", serverURL: "http://x", username: "u", password: "p")
        ctx.insert(playlist)
        let prefix = "\(playlist.id.uuidString)-"

        let hidden = Lume.Category(apiId: "2", name: "Shopping", parentId: 0, type: .live, playlist: playlist)
        hidden.isHidden = true
        let locked = Lume.Category(apiId: "3", name: "Adults", parentId: 0, type: .live, playlist: playlist)
        locked.isRestricted = true
        for category in [hidden, locked] {
            ctx.insert(category)
        }
        try ctx.save()

        // Hiding is a viewer-agnostic Content Management choice; locking only
        // applies to a child profile. The two must not be conflated.
        let restriction = ContentRestriction(isActive: false, restrictedCategoryIDs: [locked.id])
        let visible = LiveChannelQuery.visibleCategories([hidden, locked], playlistPrefix: prefix, restriction: restriction)

        #expect(visible.map(\.id) == [locked.id])
    }
}
