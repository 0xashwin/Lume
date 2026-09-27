import Foundation
@testable import Lume
import Testing

// MARK: - Bucket response

struct SimklWatchlistResponseTests {
    private func entries(_ json: String) throws -> [SimklWatchlistEntry] {
        try JSONDecoder().decode(SimklWatchlistResponse.self, from: Data(json.utf8)).entries
    }

    @Test func `movies and shows keep their kind and tmdb id`() throws {
        let result = try entries("""
        {
          "movies": [{"added_to_watchlist_at": "2026-05-15T00:13:09Z", "status": "plantowatch",
                      "movie": {"title": "Heat", "ids": {"simkl": 1, "tmdb": 949}}}],
          "shows": [{"added_to_watchlist_at": "2018-02-24T23:55:13Z", "status": "plantowatch",
                     "show": {"title": "Charmed", "ids": {"simkl": 297, "tmdb": "1981"}}}]
        }
        """)
        #expect(result.map(\.kind) == [.movie, .show])
        #expect(result.map(\.tmdbID) == [949, 1981])
        #expect(result[0].addedAt == Date(timeIntervalSince1970: 1_778_803_989))
    }

    @Test func `titles without a tmdb id are dropped`() throws {
        let result = try entries("""
        {"anime": [{"status": "plantowatch", "show": {"title": "Cowboy Bebop", "ids": {"simkl": 37089, "mal": "1"}}}]}
        """)
        #expect(result.isEmpty)
    }

    @Test func `an anime film matches as a movie`() throws {
        let result = try entries("""
        {"anime": [
          {"anime_type": "movie", "show": {"ids": {"tmdb": 129}}},
          {"anime_type": "tv", "show": {"ids": {"tmdb": 30991}}}
        ]}
        """)
        #expect(result.map(\.kind) == [.movie, .show])
    }

    @Test func `an empty bucket decodes to no entries`() throws {
        #expect(try entries("{}").isEmpty)
    }

    @Test func `an unparseable date leaves the entry undated`() throws {
        let result = try entries("""
        {"movies": [{"added_to_watchlist_at": "yesterday", "movie": {"ids": {"tmdb": 1}}}]}
        """)
        #expect(result.count == 1)
        #expect(result[0].addedAt == nil)
    }
}

// MARK: - Activities

struct SimklActivitiesTests {
    @Test func `fingerprint reads each type's block`() throws {
        let activities = try JSONDecoder().decode(SimklActivities.self, from: Data("""
        {
          "all": "2026-05-14T07:12:20Z",
          "movies": {"all": "x", "plantowatch": "2026-05-14T06:43:11Z", "removed_from_list": "2026-04-10T05:34:55Z"},
          "tv_shows": {"plantowatch": "2026-04-10T05:42:42Z", "removed_from_list": null},
          "anime": {"plantowatch": null, "removed_from_list": "2026-04-10T05:34:55Z"}
        }
        """.utf8))
        #expect(activities.fingerprint(for: .movies) == "2026-05-14T06:43:11Z|2026-04-10T05:34:55Z")
        #expect(activities.fingerprint(for: .shows) == "2026-04-10T05:42:42Z|")
        #expect(activities.fingerprint(for: .anime) == nil)
    }

    @Test func `a missing block has no fingerprint`() throws {
        let activities = try JSONDecoder().decode(SimklActivities.self, from: Data("{}".utf8))
        #expect(activities.fingerprint(for: .movies) == nil)
    }
}

// MARK: - Cache

struct SimklWatchlistCacheTests {
    private static let activities = SimklActivities(
        movies: SimklListActivity(planToWatch: "m1", removedFromList: nil),
        tvShows: SimklListActivity(planToWatch: "s1", removedFromList: "r1"),
        anime: nil
    )

    private func entry(_ tmdbID: Int, _ kind: SimklWatchlistEntry.Kind = .movie, added: TimeInterval?) -> SimklWatchlistEntry {
        SimklWatchlistEntry(kind: kind, tmdbID: tmdbID, addedAt: added.map(Date.init(timeIntervalSince1970:)))
    }

    @Test func `every bucket is stale on a cold cache`() {
        let cache = SimklWatchlistCache(username: "me")
        #expect(cache.staleBuckets(for: Self.activities) == SimklWatchlistBucket.allCases)
    }

    @Test func `only moved buckets are stale`() {
        var cache = SimklWatchlistCache(username: "me")
        cache.buckets[.movies] = .init(fingerprint: "m1|", entries: [])
        cache.buckets[.shows] = .init(fingerprint: "s1|r0", entries: [])
        cache.buckets[.anime] = .init(fingerprint: nil, entries: [])
        #expect(cache.staleBuckets(for: Self.activities) == [.shows])
    }

    @Test func `entries merge newest added first with undated last`() {
        var cache = SimklWatchlistCache(username: "me")
        cache.buckets[.movies] = .init(fingerprint: "m", entries: [entry(1, added: 100), entry(2, added: nil)])
        cache.buckets[.shows] = .init(fingerprint: "s", entries: [entry(3, .show, added: 300), entry(4, .show, added: 200)])
        cache.buckets[.anime] = .init(fingerprint: "a", entries: [entry(5, .show, added: nil)])
        #expect(cache.entries.map(\.tmdbID) == [3, 4, 1, 2, 5])
    }

    @Test func `cache round-trips through json`() throws {
        var cache = SimklWatchlistCache(username: "me")
        cache.buckets[.shows] = .init(fingerprint: "s1|r1", entries: [entry(7, .show, added: 42)])
        let decoded = try JSONDecoder().decode(SimklWatchlistCache.self, from: JSONEncoder().encode(cache))
        #expect(decoded == cache)
    }
}
