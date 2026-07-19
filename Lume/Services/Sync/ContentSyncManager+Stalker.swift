//
//  ContentSyncManager+Stalker.swift
//  Lume
//
//  The Stalker (Ministra) portal sync pipeline. Authenticates by MAC, then maps
//  the portal's `itv` / `vod` / `series` endpoints onto the same SwiftData models
//  the Xtream and m3u pipelines fill — so browsing, search, favorites and EPG all
//  work identically across source types.
//
//  Stalker hands out short-lived stream URLs, so the catalog stores each item's
//  `cmd` (in `directURL` / `directSource`) and the real URL is resolved at
//  playback time via `create_link` (see `StalkerStreamResolver`).
//

import Foundation
import OSLog
import SwiftData

extension ContentSyncManager {
    /// A positive `Int` stream id for a Stalker element. Stalker ids are numeric
    /// strings (`"123"`); fall back to a stable hash for the rare non-numeric id
    /// so element ids stay constant across re-syncs.
    private static func streamId(for stalkerId: String) -> Int {
        if let int = Int(stalkerId), int > 0 { return int }
        return M3UIdentity.numericId(for: stalkerId)
    }

    /// The Stalker pipeline: authenticate, then pull categories and content.
    ///
    /// `full` selects how much of the VOD/series catalog to pull. The portal
    /// serves ordered lists at a fixed ~14 items per page and exposes no bulk
    /// endpoint, so a large catalog (100k+ titles) is thousands of requests —
    /// tens of minutes. The default (`full == false`) therefore syncs only the
    /// newest `stalkerRecentSliceLimit` titles per kind (seconds), which fills
    /// the home rails and browse previews; the full catalog is pulled on
    /// demand by the "Download full catalog" action (`full == true`).
    func performStalkerSync(playlist: Playlist, playlistId: UUID, progress: SyncProgress?, full: Bool = false) async throws {
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))

        await progress?.start(.authenticating)
        let profile = try await client.authenticate()
        updateStalkerPlaylistInfo(playlistId, profile: profile)
        await progress?.complete(.authenticating)

        // Fetch the category/genre lists once and reuse them to both persist the
        // categories and walk each one's content.
        await progress?.start(.movieCategories)
        let vodCategories = await (try? client.getCategories(type: "vod")) ?? []
        try syncStalkerCategories(vodCategories, type: .vod, playlistId: playlistId)
        await progress?.update(detail: "\(vodCategories.count) categories")
        await progress?.complete(.movieCategories)

        await progress?.start(.seriesCategories)
        let seriesCategories = await (try? client.getCategories(type: "series")) ?? []
        try syncStalkerCategories(seriesCategories, type: .series, playlistId: playlistId)
        await progress?.update(detail: "\(seriesCategories.count) categories")
        await progress?.complete(.seriesCategories)

        await progress?.start(.liveCategories)
        let genres = await (try? client.getLiveGenres()) ?? []
        try syncStalkerCategories(genres, type: .live, playlistId: playlistId)
        await progress?.update(detail: "\(genres.count) categories")
        await progress?.complete(.liveCategories)

        try await syncStalkerMovies(client: client, categories: vodCategories, playlistId: playlistId, progress: progress, full: full)
        try await Task.sleep(for: .seconds(1))
        try await syncStalkerSeries(client: client, categories: seriesCategories, playlistId: playlistId, progress: progress, full: full)
        try await Task.sleep(for: .seconds(1))
        try await syncStalkerChannels(client: client, playlistId: playlistId, progress: progress)

        markStalkerPlaylistUpdated(playlistId)
    }

    // MARK: - Categories

    private func syncStalkerCategories(_ cats: [StalkerCategory], type: CategoryType, playlistId: UUID) throws {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false

        let lookup = buildExistingCategoryLookup(context: context, playlistId: playlistId, type: type)
        guard let playlist = try context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }

        for (index, cat) in cats.enumerated() where !cat.id.isEmpty {
            if let existing = lookup[cat.id] {
                existing.name = cat.title
                existing.sortOrder = index
                existing.lastRefreshed = Date()
            } else {
                let category = Category(apiId: cat.id, name: cat.title, parentId: 0, type: type, playlist: playlist)
                category.sortOrder = index
                category.lastRefreshed = Date()
                context.insert(category)
            }
        }
        try context.save()

        if !cats.isEmpty {
            pruneStaleCategories(playlistId: playlistId, type: type, seenApiIds: Set(cats.map(\.id)))
        }
    }

    // MARK: - Catalog walk (vod / series)

    /// How many newest titles the default (non-full) sync pulls per content
    /// kind. The portal serves ~14 items per page with no bulk endpoint, so a
    /// large catalog can't be synced whole in reasonable time; this slice fills
    /// the home rails and browse previews in seconds. The full catalog is
    /// available via the "Download full catalog" action (`full == true`).
    static let stalkerRecentSliceLimit = 3000

    // swiftlint:disable function_parameter_count
    /// Walks a portal's `vod` or `series` catalog and upserts it in fixed-size
    /// batches (mirroring `syncStalkerChannels` and the Xtream/m3u pipelines —
    /// one save, and one main-context merge, per batch rather than per
    /// category). Returns the imported count, every element id seen, and
    /// whether the walk reached the end of the catalog (vs. stopping at the
    /// recent-slice cap).
    ///
    /// Ministra portals expose a `*` "All" pseudo-category whose items each
    /// carry their real `category_id`, so one walk over it (newest first)
    /// covers every category in ceil(total / page-size) requests. Walking
    /// category by category instead re-pages the same catalog once per
    /// category — tens of thousands of sequential requests on large portals.
    /// The per-category walk remains only as the fallback for portals without
    /// `*`; those can't be recency-sliced across categories, so they ignore
    /// `limit` and always walk fully (they're small in practice).
    private func syncStalkerCatalog(
        client: StalkerClient,
        type: String,
        categories: [StalkerCategory],
        limit: Int?,
        progress: SyncProgress?,
        upsert: ([(item: StalkerVODItem, categoryId: String)], inout Set<String>) -> Int
    ) async throws -> (imported: Int, seenIds: Set<String>, complete: Bool) {
        var seenIds = Set<String>()
        var imported = 0
        let batchSize = 2000
        var pending: [(item: StalkerVODItem, categoryId: String)] = []
        var walkedFullCatalog = true

        if categories.contains(where: { $0.id == "*" }) {
            let cap = limit ?? Int.max
            let walk = await (try? client.getAllOrderedItems(type: type, categoryId: "*", maxItems: cap) { count, total in
                // Progress targets the smaller of the reported total and the
                // slice cap, so the bar fills to 100% on a capped sync.
                let target = min(total ?? count, cap)
                await progress?.update(
                    detail: "\(min(count, target)) of \(target)",
                    fraction: target > 0 ? Double(min(count, target)) / Double(target) : 0
                )
            })
            // A capped walk stops early (complete == false) by design; only a
            // walk that reached the catalog's end should authorize pruning.
            walkedFullCatalog = walk?.complete ?? false
            pending = (walk?.items ?? []).map { (item: $0, categoryId: $0.categoryId ?? "*") }
        } else {
            for category in categories where !category.id.isEmpty {
                try Task.checkCancellation()
                let walk = await (try? client.getAllOrderedItems(type: type, categoryId: category.id))
                if walk?.complete != true { walkedFullCatalog = false }
                let items = walk?.items ?? []
                guard !items.isEmpty else { continue }

                pending.append(contentsOf: items.map { (item: $0, categoryId: category.id) })
                while pending.count >= batchSize {
                    let batch = Array(pending.prefix(batchSize))
                    pending.removeFirst(batchSize)
                    autoreleasepool {
                        imported += upsert(batch, &seenIds)
                    }
                }
                await progress?.update(detail: "\(imported + pending.count) items")
            }
        }
        while !pending.isEmpty {
            try Task.checkCancellation()
            let batch = Array(pending.prefix(batchSize))
            pending.removeFirst(batch.count)
            autoreleasepool {
                imported += upsert(batch, &seenIds)
            }
        }
        return (imported, seenIds, walkedFullCatalog)
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Movies (vod)

    private func syncStalkerMovies(
        client: StalkerClient,
        categories: [StalkerCategory],
        playlistId: UUID,
        progress: SyncProgress?,
        full: Bool
    ) async throws {
        await progress?.start(.movies)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.vod.rawValue)-"
        let result = try await syncStalkerCatalog(
            client: client, type: "vod", categories: categories,
            limit: full ? nil : Self.stalkerRecentSliceLimit, progress: progress
        ) { batch, seenIds in
            upsertStalkerMovies(
                batch, playlistPrefix: playlistPrefix,
                playlistId: playlistId, seenIds: &seenIds
            )
        }

        // Prune only after a full walk reached the catalog's end. A capped
        // (default) sync stops early, so its `seenIds` is a partial slice —
        // pruning against it would delete everything outside the newest slice,
        // including a full catalog a prior "Download full catalog" pulled.
        if result.complete, !result.seenIds.isEmpty {
            pruneStaleMovies(playlistId: playlistId, seenIds: result.seenIds)
        }
        // A completed full walk pulled every category's content, so none needs
        // an on-demand fetch when opened.
        if full, result.complete {
            markAllStalkerCategoriesImported(type: .vod, playlistId: playlistId)
        }
        let imported = result.imported
        Logger.database.info("Stalker: synced \(imported) movies (full: \(full))")
        await progress?.complete(.movies)
    }

    /// Upserts one batch of VOD items (each carrying its category) on a fresh
    /// context and returns how many were imported.
    private func upsertStalkerMovies(
        _ items: [(item: StalkerVODItem, categoryId: String)],
        playlistPrefix: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.compactMap { entry -> String? in
            guard let stalkerId = entry.item.id else { return nil }
            return "\(playlistId.uuidString)-movie-\(Self.streamId(for: stalkerId))"
        }
        var existing: [String: Movie] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Movie>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for movie in fetched {
            existing[movie.id] = movie
        }

        var imported = 0
        for (item, categoryId) in items {
            guard let stalkerId = item.id, let cmd = item.cmd else { continue }
            let streamId = Self.streamId(for: stalkerId)
            let movieId = "\(playlistId.uuidString)-movie-\(streamId)"
            seenIds.insert(movieId)

            let movie: Movie
            if let found = existing[movieId] {
                movie = found
            } else {
                movie = Movie(id: movieId, streamId: streamId, name: "")
                context.insert(movie)
            }
            movie.name = item.name ?? ""
            movie.streamIcon = item.screenshot
            movie.plot = item.description
            movie.releaseDate = item.year
            movie.rating = Double(item.rating ?? "") ?? movie.rating
            movie.added = item.added ?? movie.added
            movie.categoryId = playlistPrefix + categoryId
            movie.directURL = cmd
            imported += 1
        }
        try? context.save()
        return imported
    }

    // MARK: - Series

    private func syncStalkerSeries(
        client: StalkerClient,
        categories: [StalkerCategory],
        playlistId: UUID,
        progress: SyncProgress?,
        full: Bool
    ) async throws {
        await progress?.start(.series)
        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.series.rawValue)-"
        let result = try await syncStalkerCatalog(
            client: client, type: "series", categories: categories,
            limit: full ? nil : Self.stalkerRecentSliceLimit, progress: progress
        ) { batch, seenIds in
            upsertStalkerSeries(
                batch, playlistPrefix: playlistPrefix,
                playlistId: playlistId, seenIds: &seenIds
            )
        }

        // Prune only after a full walk reached the catalog's end — see
        // `syncStalkerMovies`.
        if result.complete, !result.seenIds.isEmpty {
            pruneStaleSeries(playlistId: playlistId, seenIds: result.seenIds)
        }
        if full, result.complete {
            markAllStalkerCategoriesImported(type: .series, playlistId: playlistId)
        }
        let imported = result.imported
        Logger.database.info("Stalker: synced \(imported) series (full: \(full))")
        await progress?.complete(.series)
    }

    /// Upserts one batch of series items (each carrying its category) on a
    /// fresh context and returns how many were imported.
    private func upsertStalkerSeries(
        _ items: [(item: StalkerVODItem, categoryId: String)],
        playlistPrefix: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) -> Int {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = items.compactMap { entry -> String? in
            guard let stalkerId = entry.item.id else { return nil }
            return "\(playlistId.uuidString)-series-\(Self.streamId(for: stalkerId))"
        }
        var existing: [String: Series] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<Series>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for series in fetched {
            existing[series.id] = series
        }

        var imported = 0
        for (item, categoryId) in items {
            guard let stalkerId = item.id else { continue }
            let seriesId = Self.streamId(for: stalkerId)
            let id = "\(playlistId.uuidString)-series-\(seriesId)"
            seenIds.insert(id)

            let series: Series
            if let found = existing[id] {
                series = found
            } else {
                series = Series(id: id, seriesId: seriesId, name: "")
                context.insert(series)
            }
            series.name = item.name ?? ""
            series.cover = item.screenshot
            series.plot = item.description
            series.releaseDate = item.year
            // The Recently Added series rail orders by `lastModified`; the
            // portal's `added` timestamp is the closest equivalent.
            series.lastModified = item.added ?? series.lastModified
            series.categoryId = playlistPrefix + categoryId
            imported += 1
        }
        try? context.save()
        return imported
    }

    /// Fetches a Stalker series' episodes on demand (the series detail screen
    /// calls this through `fetchEpisodes`). Best-effort: the portal returns each
    /// episode as an ordered-list item carrying its own `cmd`, which is stored in
    /// `directSource` for playback-time `create_link` resolution. Portals that
    /// don't expose episodes this way yield an empty list, leaving the series
    /// browsable with no episodes rather than failing.
    func fetchStalkerEpisodes(seriesId: Int, seriesElementId: String, playlist: Playlist) async throws -> [ParsedEpisode] {
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
        let items = try await client.getAllOrderedItems(
            type: "series",
            categoryId: "*",
            movieId: String(seriesId),
            maxItems: 2000
        ).items
        var result: [ParsedEpisode] = []
        for (index, item) in items.enumerated() {
            guard let cmd = item.cmd else { continue }
            // Stalker series carry a flat episode list; use the provider order
            // (1-based) for the episode number and group everything under one
            // season, which is how most portals present a series.
            let episodeNumbers = item.seriesNumbers.isEmpty ? [index + 1] : item.seriesNumbers
            for episodeNum in episodeNumbers {
                let episodeKey = "\(item.id ?? "\(index)")-\(episodeNum)"
                result.append(ParsedEpisode(
                    id: "\(seriesElementId)-episode-\(episodeKey)",
                    episodeId: episodeKey,
                    title: item.name ?? "",
                    containerExtension: "mpegts",
                    seasonNum: 1,
                    episodeNum: episodeNum,
                    added: nil,
                    directSource: cmd,
                    durationSecs: nil,
                    movieImage: item.screenshot,
                    rating: nil,
                    airDate: item.year,
                    plot: item.description
                ))
            }
        }
        return result
    }

    // MARK: - On-demand category import

    /// One Stalker VOD/series category's full content, fetched from the portal
    /// and upserted, with the category marked imported so opening it again
    /// reads local rows. The default sync only seeds the newest slice across
    /// all categories (see `stalkerRecentSliceLimit`), so a specific category
    /// is otherwise near-empty until the user opens it. Returns the number of
    /// items imported. Marks the category imported only when the walk reached
    /// its end, so a truncated fetch retries on the next open.
    @discardableResult
    func importStalkerCategory(apiId: String, type: CategoryType, playlist: Playlist) async throws -> Int {
        guard type == .vod || type == .series, !apiId.isEmpty else { return 0 }
        let client = StalkerClient(configuration: StalkerClient.Configuration(playlist: playlist))
        let playlistId = playlist.id
        let walk = try await client.getAllOrderedItems(
            type: type == .vod ? "vod" : "series", categoryId: apiId
        )
        let playlistPrefix = "\(playlistId.uuidString)-\(type.rawValue)-"
        let entries = walk.items.map { (item: $0, categoryId: apiId) }

        var seen = Set<String>()
        var imported = 0
        let batchSize = 2000
        for start in stride(from: 0, to: entries.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(entries[start ..< min(start + batchSize, entries.count)])
            autoreleasepool {
                switch type {
                case .vod:
                    imported += upsertStalkerMovies(
                        batch, playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seen
                    )
                case .series:
                    imported += upsertStalkerSeries(
                        batch, playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seen
                    )
                case .live:
                    break
                }
            }
        }
        if walk.complete {
            markStalkerCategoryImported(apiId: apiId, type: type, playlistId: playlistId)
        }
        Logger.database.info("Stalker: imported \(imported) items for category \(apiId)")
        return imported
    }

    /// Stamps one category's `contentImportedAt`.
    private func markStalkerCategoryImported(apiId: String, type: CategoryType, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let categoryId = "\(playlistId.uuidString)-\(type.rawValue)-\(apiId)"
        guard let category = try? context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.id == categoryId })
        ).first else { return }
        category.contentImportedAt = Date()
        try? context.save()
    }

    /// Stamps every category of `type` imported — used after a completed full
    /// catalog download, which already pulled all of them.
    private func markAllStalkerCategoriesImported(type: CategoryType, playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let typeRaw = type.rawValue
        let prefix = playlistId.uuidString
        let cats = (try? context.fetch(
            FetchDescriptor<Category>(predicate: #Predicate { $0.typeRaw == typeRaw })
        )) ?? []
        let now = Date()
        for category in cats where category.id.hasPrefix(prefix) {
            category.contentImportedAt = now
        }
        try? context.save()
    }

    // MARK: - Live channels (itv)

    private func syncStalkerChannels(
        client: StalkerClient,
        playlistId: UUID,
        progress: SyncProgress?
    ) async throws {
        await progress?.start(.liveStreams)
        let channels = try await client.getAllChannels()
        let totalCount = channels.count
        await progress?.update(detail: "0 of \(totalCount)", fraction: 0)

        let playlistPrefix = "\(playlistId.uuidString)-\(CategoryType.live.rawValue)-"
        var seenIds = Set<String>()
        // Local copy: ContentSyncManager.batchSize is file-private to the main
        // file, so it isn't visible from this extension.
        let batchSize = 2000

        for batchStart in stride(from: 0, to: totalCount, by: batchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + batchSize, totalCount)
            autoreleasepool {
                upsertStalkerChannels(
                    Array(channels[batchStart ..< batchEnd]),
                    playlistPrefix: playlistPrefix, playlistId: playlistId, seenIds: &seenIds
                )
            }
            await progress?.update(
                detail: "\(batchEnd) of \(totalCount)",
                fraction: totalCount == 0 ? 1 : Double(batchEnd) / Double(totalCount)
            )
        }

        if !seenIds.isEmpty {
            pruneStaleLiveStreams(playlistId: playlistId, seenIds: seenIds)
        }
        Logger.database.info("Stalker: synced \(totalCount) live channels")
        await progress?.complete(.liveStreams)
    }

    /// Upserts one batch of channels on a fresh context.
    private func upsertStalkerChannels(
        _ channels: [StalkerChannel],
        playlistPrefix: String,
        playlistId: UUID,
        seenIds: inout Set<String>
    ) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        let ids = channels.compactMap { channel -> String? in
            guard let stalkerId = channel.id else { return nil }
            return "\(playlistId.uuidString)-live-\(Self.streamId(for: stalkerId))"
        }
        var existing: [String: LiveStream] = [:]
        let fetched = (try? context.fetch(
            FetchDescriptor<LiveStream>(predicate: #Predicate { ids.contains($0.id) })
        )) ?? []
        for stream in fetched {
            existing[stream.id] = stream
        }

        for channel in channels {
            guard let stalkerId = channel.id, let cmd = channel.cmd else { continue }
            let streamId = Self.streamId(for: stalkerId)
            let id = "\(playlistId.uuidString)-live-\(streamId)"
            seenIds.insert(id)

            let stream: LiveStream
            if let found = existing[id] {
                stream = found
            } else {
                stream = LiveStream(id: id, streamId: streamId, name: "")
                context.insert(stream)
            }
            stream.name = channel.name ?? ""
            stream.streamIcon = channel.logo
            stream.epgChannelId = channel.xmltvId
            stream.directURL = cmd
            stream.num = channel.number ?? 0
            if let genreId = channel.genreId {
                stream.categoryId = playlistPrefix + genreId
            }
        }
        try? context.save()
    }

    // MARK: - Playlist bookkeeping

    private func updateStalkerPlaylistInfo(_ playlistId: UUID, profile: StalkerProfile) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.userStatus = profile.status
        playlist.expDate = profile.expDate
        playlist.lastUpdated = Date()
        try? context.save()
    }

    private func markStalkerPlaylistUpdated(_ playlistId: UUID) {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        guard let playlist = try? context.fetch(
            FetchDescriptor<Playlist>(predicate: #Predicate { $0.id == playlistId })
        ).first else { return }
        playlist.lastUpdated = Date()
        try? context.save()
    }
}
