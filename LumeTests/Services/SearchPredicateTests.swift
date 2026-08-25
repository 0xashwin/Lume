//
//  SearchPredicateTests.swift
//  LumeTests
//
//  Search excludes hidden/restricted categories inside the fetch, so the
//  per-type result limit isn't spent on rows the viewer will never see. The
//  predicates must run against an on-disk SQLite store: in-memory stores
//  evaluate predicates without SQL generation, so a form CoreData can't render
//  passes there and traps on device (see `TmdbIdPredicateTests`).
//

import Foundation
@testable import Lume
import SwiftData
import Testing

@MainActor
struct SearchPredicateTests {
    /// The container must be held for the test's duration — a
    /// `makeSQLiteContainer().mainContext` temporary deallocates the store out
    /// from under the context and traps inside SwiftData on the first save.
    private func makeSQLiteContainer() throws -> ModelContainer {
        let schema = Schema([
            Playlist.self, Lume.Category.self, LiveStream.self, Movie.self,
            Series.self, Episode.self, CastMember.self, EPGListing.self, EPGSource.self
        ])
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("catalog.store")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func scope(query: String, excluded: Set<String> = []) -> SearchScope {
        SearchScope(query: query, playlistID: "", restrictToPlaylist: false, excluded: excluded)
    }

    private func insertMovies(_ context: ModelContext) throws {
        for (id, category) in [("m1", "en"), ("m2", "nl")] {
            let movie = Movie(id: id, streamId: 1, name: "The Matrix")
            movie.categoryId = category
            context.insert(movie)
        }
        // An uncategorised title — m3u sources don't always supply a category.
        let orphan = Movie(id: "m3", streamId: 3, name: "The Matrix")
        context.insert(orphan)
        try context.save()
    }

    @Test func `movie search drops excluded categories and keeps uncategorised titles`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        try insertMovies(context)

        let fetched = try context.fetch(
            FetchDescriptor<Movie>(predicate: searchMoviePredicate(scope: scope(query: "matrix", excluded: ["nl"])))
        )
        #expect(Set(fetched.map(\.id)) == ["m1", "m3"])
    }

    @Test func `movie search returns everything when nothing is excluded`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        try insertMovies(context)

        let fetched = try context.fetch(
            FetchDescriptor<Movie>(predicate: searchMoviePredicate(scope: scope(query: "matrix")))
        )
        #expect(Set(fetched.map(\.id)) == ["m1", "m2", "m3"])
    }

    @Test func `series search drops excluded categories`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let visible = Series(id: "s1", seriesId: 1, name: "Dark Matter")
        visible.categoryId = "en"
        let hidden = Series(id: "s2", seriesId: 2, name: "Dark Matter")
        hidden.categoryId = "nl"
        context.insert(visible)
        context.insert(hidden)
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<Series>(predicate: searchSeriesPredicate(scope: scope(query: "dark", excluded: ["nl"])))
        )
        #expect(fetched.map(\.id) == ["s1"])
    }

    @Test func `live search drops excluded categories and individually hidden channels`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let visible = LiveStream(id: "l1", streamId: 1, name: "News One")
        visible.categoryId = "en"
        let inHiddenCategory = LiveStream(id: "l2", streamId: 2, name: "News Two")
        inHiddenCategory.categoryId = "nl"
        let hiddenChannel = LiveStream(id: "l3", streamId: 3, name: "News Three")
        hiddenChannel.categoryId = "en"
        hiddenChannel.isHidden = true
        for stream in [visible, inHiddenCategory, hiddenChannel] {
            context.insert(stream)
        }
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<LiveStream>(
                predicate: searchLiveStreamPredicate(scope: scope(query: "news", excluded: ["nl"]))
            )
        )
        #expect(fetched.map(\.id) == ["l1"])
    }

    @Test func `playlist scoping still applies alongside the exclusion`() throws {
        let container = try makeSQLiteContainer()
        let context = container.mainContext
        let mine = Movie(id: "m1", streamId: 1, name: "The Matrix")
        mine.categoryId = "PL-A-vod-1"
        let other = Movie(id: "m2", streamId: 2, name: "The Matrix")
        other.categoryId = "PL-B-vod-1"
        context.insert(mine)
        context.insert(other)
        try context.save()

        let fetched = try context.fetch(
            FetchDescriptor<Movie>(predicate: searchMoviePredicate(scope: SearchScope(
                query: "matrix", playlistID: "PL-A", restrictToPlaylist: true, excluded: ["nl"]
            )))
        )
        #expect(fetched.map(\.id) == ["m1"])
    }
}
