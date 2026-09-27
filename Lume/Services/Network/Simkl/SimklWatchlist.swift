//
//  SimklWatchlist.swift
//  Lume
//
//  The Simkl "Plan to Watch" list behind Home's Simkl watchlist row, and the
//  on-disk copy that keeps it from being re-downloaded.
//
//  Simkl suspends a `client_id` that pulls `/sync/all-items` without first
//  checking `/sync/activities`, so the list is never fetched on a schedule of
//  its own: each Home load asks for the (tiny) activities stamps and refetches
//  only the per-type buckets whose `plantowatch` or `removed_from_list` stamp
//  moved since the cached copy was taken. Removals don't surface through
//  `date_from`, which is why a moved bucket is refetched whole rather than
//  patched with a delta — a watchlist is small, and it only moves when the user
//  edits it.
//
//  Derived state, not user data: it lives in Caches, belongs to one Simkl
//  account, and is deleted on disconnect.
//

import Foundation
import OSLog

// MARK: - Client

nonisolated extension SimklClient {
    /// When each of the user's lists last changed. Simkl requires this before
    /// any `/sync/all-items` read.
    func activities(accessToken: String) async throws -> SimklActivities {
        try await get("/sync/activities", accessToken: accessToken)
    }

    /// One type's "Plan to Watch" bucket, reduced to its TMDB-matchable titles.
    /// An account with nothing in any list answers `null`, which decodes to nil.
    func planToWatch(_ bucket: SimklWatchlistBucket, accessToken: String) async throws -> [SimklWatchlistEntry] {
        let response: SimklWatchlistResponse? = try await get(
            "/sync/all-items/\(bucket.rawValue)/plantowatch",
            accessToken: accessToken
        )
        return response?.entries ?? []
    }
}

// MARK: - Buckets

/// One per-type `plantowatch` bucket, named by its `/sync/all-items` path
/// segment. The raw value is also the cache key, so cases must not be renamed.
nonisolated enum SimklWatchlistBucket: String, CaseIterable, Codable {
    case movies
    case shows
    case anime
}

// MARK: - Entries

/// A watchlist title reduced to what Home matches on: movie or show, and its
/// TMDB id. Titles without a TMDB id can't match the catalog and are dropped.
nonisolated struct SimklWatchlistEntry: Codable, Equatable {
    enum Kind: String, Codable {
        case movie
        case show
    }

    let kind: Kind
    let tmdbID: Int
    let addedAt: Date?
}

// MARK: - Activities

/// The slice of `/sync/activities` the watchlist reads: per type, when the
/// `plantowatch` bucket last changed and when anything was deleted outright.
nonisolated struct SimklActivities: Decodable {
    let movies: SimklListActivity?
    let tvShows: SimklListActivity?
    let anime: SimklListActivity?

    enum CodingKeys: String, CodingKey {
        case movies
        case tvShows = "tv_shows"
        case anime
    }

    /// Identifies the current state of one bucket; the cached copy is stale when
    /// this differs from the fingerprint it was stored under. Nil when the
    /// bucket has never had a title in it, so it's known empty without a fetch.
    func fingerprint(for bucket: SimklWatchlistBucket) -> String? {
        let activity = switch bucket {
        case .movies: movies
        case .shows: tvShows
        case .anime: anime
        }
        guard let planToWatch = activity?.planToWatch else { return nil }
        return "\(planToWatch)|\(activity?.removedFromList ?? "")"
    }
}

nonisolated struct SimklListActivity: Decodable {
    let planToWatch: String?
    let removedFromList: String?

    enum CodingKeys: String, CodingKey {
        case planToWatch = "plantowatch"
        case removedFromList = "removed_from_list"
    }
}

// MARK: - Bucket response

/// Decoded `/sync/all-items/{type}/plantowatch` payload. Filtered calls carry
/// only their own key, and an empty bucket answers `{}`.
nonisolated struct SimklWatchlistResponse: Decodable {
    let movies: [SimklWatchlistItem]
    let shows: [SimklWatchlistItem]
    let anime: [SimklWatchlistItem]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        movies = try container.decodeIfPresent([SimklWatchlistItem].self, forKey: .movies) ?? []
        shows = try container.decodeIfPresent([SimklWatchlistItem].self, forKey: .shows) ?? []
        anime = try container.decodeIfPresent([SimklWatchlistItem].self, forKey: .anime) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case movies, shows, anime
    }

    /// Every item that carries a TMDB id. An anime film is a TMDB *movie*, so it
    /// matches the movie catalog rather than the series one.
    var entries: [SimklWatchlistEntry] {
        let movieEntries = movies.compactMap { $0.entry(kind: .movie, media: $0.movie) }
        let showEntries = shows.compactMap { $0.entry(kind: .show, media: $0.show) }
        let animeEntries = anime.compactMap { item in
            item.entry(kind: item.animeType == "movie" ? .movie : .show, media: item.show ?? item.movie)
        }
        return movieEntries + showEntries + animeEntries
    }
}

nonisolated struct SimklWatchlistItem: Decodable {
    let addedToWatchlistAt: String?
    let animeType: String?
    let movie: SimklWatchedMedia?
    let show: SimklWatchedMedia?

    enum CodingKeys: String, CodingKey {
        case addedToWatchlistAt = "added_to_watchlist_at"
        case animeType = "anime_type"
        case movie, show
    }

    fileprivate func entry(kind: SimklWatchlistEntry.Kind, media: SimklWatchedMedia?) -> SimklWatchlistEntry? {
        guard let tmdbID = media?.ids.tmdb else { return nil }
        let addedAt = addedToWatchlistAt.flatMap { try? Date($0, strategy: .iso8601) }
        return SimklWatchlistEntry(kind: kind, tmdbID: tmdbID, addedAt: addedAt)
    }
}

// MARK: - Cache

/// The cached watchlist of one Simkl account: each bucket's entries plus the
/// activities fingerprint they were fetched under.
nonisolated struct SimklWatchlistCache: Codable, Equatable {
    struct Bucket: Codable, Equatable {
        var fingerprint: String?
        var entries: [SimklWatchlistEntry]
    }

    let username: String
    var buckets: [SimklWatchlistBucket: Bucket] = [:]

    /// Buckets whose cached copy no longer matches `activities`. A bucket never
    /// cached is always stale — except one Simkl reports has never been used,
    /// which is stored as empty without a request.
    func staleBuckets(for activities: SimklActivities) -> [SimklWatchlistBucket] {
        SimklWatchlistBucket.allCases.filter { bucket in
            guard let cached = buckets[bucket] else { return true }
            return cached.fingerprint != activities.fingerprint(for: bucket)
        }
    }

    /// Every bucket's entries merged, most recently added first — the order a
    /// watchlist reads in on simkl.com. Undated entries sink to the end.
    var entries: [SimklWatchlistEntry] {
        SimklWatchlistBucket.allCases
            .flatMap { buckets[$0]?.entries ?? [] }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsDate = lhs.element.addedAt ?? .distantPast
                let rhsDate = rhs.element.addedAt ?? .distantPast
                return lhsDate == rhsDate ? lhs.offset < rhs.offset : lhsDate > rhsDate
            }
            .map(\.element)
    }
}

// MARK: - Store

/// Reads and writes ``SimklWatchlistCache`` in the Caches directory.
enum SimklWatchlistStore {
    private static let logger = Logger(subsystem: "com.bilipp.lume", category: "SimklWatchlist")

    static var fileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SimklWatchlist.json")
    }

    /// The cached watchlist, or nil when there is none for `username` — a
    /// different account's copy is never handed back.
    static func load(for username: String) -> SimklWatchlistCache? {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(SimklWatchlistCache.self, from: data),
              cache.username == username
        else { return nil }
        return cache
    }

    static func save(_ cache: SimklWatchlistCache) {
        guard let url = fileURL else { return }
        do {
            try JSONEncoder().encode(cache).write(to: url, options: .atomic)
        } catch {
            logger.error("Couldn't save the Simkl watchlist: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
