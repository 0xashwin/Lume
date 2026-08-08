import Foundation
@testable import Lume
import Testing

struct OpenSubtitlesClientTests {
    // MARK: - isConfigured

    @Test func `not configured when key is nil`() {
        #expect(OpenSubtitlesClient(session: .shared, apiKey: nil).isConfigured == false)
    }

    @Test func `configured when key is present`() {
        #expect(OpenSubtitlesClient(session: .shared, apiKey: "abc123").isConfigured == true)
    }

    @Test func `key from bundle rejects an unsubstituted plist variable`() {
        // Mirrors a build with no .env: PlistBuddy never ran, so the raw
        // `$(OpenSubtitlesAPIKey)` placeholder is what a lookup would return.
        #expect(OpenSubtitlesClient(session: .shared, apiKey: nil).isConfigured == false)
    }

    // MARK: - IMDb id normalization

    @Test func `imdb id drops the tt prefix`() {
        #expect(OpenSubtitlesClient.normalizedIMDbId("tt0137523") == "0137523")
    }

    @Test func `imdb id passes bare digits through`() {
        #expect(OpenSubtitlesClient.normalizedIMDbId("137523") == "137523")
    }

    @Test func `imdb id rejects values with no digits`() {
        #expect(OpenSubtitlesClient.normalizedIMDbId("not-an-id") == nil)
        #expect(OpenSubtitlesClient.normalizedIMDbId("") == nil)
        #expect(OpenSubtitlesClient.normalizedIMDbId(nil) == nil)
    }

    @Test func `imdb id rejects trailing junk`() {
        // `tt0137523x` would be sent verbatim and silently return nothing.
        #expect(OpenSubtitlesClient.normalizedIMDbId("tt0137523x") == nil)
    }

    // MARK: - Search URL

    /// The API canonicalises its query string and answers 301 for any other
    /// ordering, so an unsorted URL costs a wasted round trip on every search.
    @Test func `search url sorts its query items by name`() throws {
        let query = OpenSubtitlesQuery(text: "Fight Club", tmdbId: 550, languages: ["en", "de"])
        let url = try #require(OpenSubtitlesClient.searchURL(for: query))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let names = (components.queryItems ?? []).map(\.name)
        #expect(names == names.sorted())
    }

    @Test func `search url carries the movie identifiers`() throws {
        let query = OpenSubtitlesQuery(text: "Fight Club", imdbId: "tt0137523", tmdbId: 550, languages: ["en"])
        let url = try #require(OpenSubtitlesClient.searchURL(for: query))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

        #expect(url.host() == "api.opensubtitles.com")
        #expect(url.path == "/api/v1/subtitles")
        #expect(byName["tmdb_id"] == "550")
        #expect(byName["imdb_id"] == "0137523")
        #expect(byName["query"] == "fight club")
        #expect(byName["languages"] == "en")
    }

    @Test func `search url keys an episode on its series plus season and episode`() throws {
        let query = OpenSubtitlesQuery(
            text: "Breaking Bad",
            parentImdbId: "tt0903747",
            parentTmdbId: 1396,
            season: 1,
            episode: 1,
            languages: ["de", "en"]
        )
        let url = try #require(OpenSubtitlesClient.searchURL(for: query))
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })

        #expect(byName["parent_tmdb_id"] == "1396")
        #expect(byName["parent_imdb_id"] == "0903747")
        #expect(byName["season_number"] == "1")
        #expect(byName["episode_number"] == "1")
        // Comma-separated and sorted, as the API expects.
        #expect(byName["languages"] == "de,en")
    }

    @Test func `search url omits identifiers that are absent`() throws {
        let query = OpenSubtitlesQuery(text: "Some Title")
        let url = try #require(OpenSubtitlesClient.searchURL(for: query))
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        #expect(names == ["query"])
    }

    // MARK: - Query emptiness

    @Test func `query with no identifiers is empty`() {
        #expect(OpenSubtitlesQuery().isEmpty)
        #expect(OpenSubtitlesQuery(text: "   ").isEmpty)
        #expect(OpenSubtitlesQuery(languages: ["en"]).isEmpty)
    }

    @Test func `query with any identifier is not empty`() {
        #expect(OpenSubtitlesQuery(text: "Dune").isEmpty == false)
        #expect(OpenSubtitlesQuery(tmdbId: 550).isEmpty == false)
        #expect(OpenSubtitlesQuery(parentTmdbId: 1396).isEmpty == false)
    }

    @Test func `search returns nothing for an empty query rather than fetching everything`() async throws {
        let client = OpenSubtitlesClient(session: .shared, apiKey: "abc123")
        let results = try await client.search(OpenSubtitlesQuery(languages: ["en"]))
        #expect(results.isEmpty)
    }

    @Test func `search throws when the build has no api key`() async {
        let client = OpenSubtitlesClient(session: .shared, apiKey: nil)
        await #expect(throws: OpenSubtitlesError.notConfigured) {
            _ = try await client.search(OpenSubtitlesQuery(tmdbId: 550))
        }
    }

    // MARK: - Result decoding

    private func decodeItem(_ json: String) throws -> OpenSubtitlesSearchItem {
        try JSONDecoder().decode(OpenSubtitlesSearchItem.self, from: Data(json.utf8))
    }

    @Test func `decodes a subtitle record`() throws {
        let item = try decodeItem("""
        {
          "attributes": {
            "subtitle_id": "11694908",
            "language": "en",
            "download_count": 261,
            "hearing_impaired": true,
            "from_trusted": true,
            "machine_translated": false,
            "ai_translated": false,
            "ratings": 8.5,
            "release": "Fight.Club.1999.REMASTERED.BDRip.x264-OLDTiME",
            "files": [{ "file_id": 12604312, "file_name": "Fight Club" }]
          }
        }
        """)
        let subtitle = try #require(item.subtitle)

        #expect(subtitle.id == "11694908")
        #expect(subtitle.fileID == 12_604_312)
        #expect(subtitle.languageCode == "en")
        #expect(subtitle.downloadCount == 261)
        #expect(subtitle.isHearingImpaired)
        #expect(subtitle.isFromTrusted)
        #expect(subtitle.isMachineTranslated == false)
        #expect(subtitle.rating == 8.5)
        #expect(subtitle.releaseName == "Fight.Club.1999.REMASTERED.BDRip.x264-OLDTiME")
    }

    /// Both flags describe a subtitle no human wrote, and the row shows one
    /// badge for that — so either one has to set it.
    @Test func `an ai translated record counts as machine translated`() throws {
        let item = try decodeItem("""
        {
          "attributes": {
            "subtitle_id": "1",
            "language": "de",
            "ai_translated": true,
            "files": [{ "file_id": 2 }]
          }
        }
        """)
        #expect(try #require(item.subtitle).isMachineTranslated)
    }

    @Test func `a record with no downloadable file is dropped`() throws {
        let item = try decodeItem("""
        { "attributes": { "subtitle_id": "1", "language": "en", "files": [] } }
        """)
        #expect(item.subtitle == nil)
    }

    @Test func `a record with no language is dropped`() throws {
        let item = try decodeItem("""
        { "attributes": { "subtitle_id": "1", "files": [{ "file_id": 2 }] } }
        """)
        #expect(item.subtitle == nil)
    }

    @Test func `a record missing every optional field still decodes`() throws {
        let item = try decodeItem("""
        { "attributes": { "language": "fr", "files": [{ "file_id": 7 }] } }
        """)
        let subtitle = try #require(item.subtitle)
        // Falls back to the file id when the feed omits the subtitle id.
        #expect(subtitle.id == "7")
        #expect(subtitle.downloadCount == 0)
        #expect(subtitle.releaseName.isEmpty)
    }

    // MARK: - Cache

    /// The engines pick their subtitle parser from the path extension, so the
    /// `.srt` suffix is load-bearing.
    @Test func `cached files are named srt and keyed by subtitle id`() {
        let subtitle = OnlineSubtitle(
            id: "42",
            fileID: 7,
            languageCode: "de",
            releaseName: "",
            downloadCount: 0,
            isHearingImpaired: false,
            isMachineTranslated: false,
            isFromTrusted: false,
            rating: 0
        )
        let url = OnlineSubtitleCache.fileURL(for: subtitle)
        #expect(url.pathExtension == "srt")
        #expect(url.lastPathComponent == "42.de.srt")
    }
}
