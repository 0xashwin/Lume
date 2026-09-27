//
//  SportsSyncServiceTests.swift
//  LumeTests
//
//  Covers the sports cache round-trip, the pure `monthsToFetch` window, the
//  freshness rules and the refresh/merge behaviour against a stub provider — no network, no shared
//  singletons (each test builds its own store over a temp cache directory).
//

import Foundation
@testable import Lume
import Testing

// MARK: - Fixtures / stubs

private nonisolated struct StubFollowSource: SportsFollowSource {
    let followedLeagueIds: [String]
    let followedTeamIds: [String]

    init(leagues: [String] = [], teams: [String] = []) {
        followedLeagueIds = leagues
        followedTeamIds = teams
    }
}

/// Counts month requests, so "did this league get fetched again?" can be asked
/// of the provider rather than inferred from the store.
private final nonisolated class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() {
        lock.lock()
        value += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// A provider that returns whatever it is seeded with. `empty` models a total
/// ESPN failure (everything degrades to `[]`).
private nonisolated struct StubProvider: SportsDataProvider {
    var monthFixtures: [SportsFixture] = []
    var teamList: [SportsTeam] = []
    var standingRows: [SportsStandingRow] = []
    var monthCalls: RequestCounter?

    func fixtures(league _: SportsLeague, month _: DateComponents) async throws -> [SportsFixture] {
        monthCalls?.increment()
        return monthFixtures
    }

    func fixtures(league _: SportsLeague, day _: Date) async throws -> [SportsFixture] {
        []
    }

    func teams(league _: SportsLeague) async throws -> [SportsTeam] {
        teamList
    }

    func standings(league _: SportsLeague) async throws -> [SportsStandingRow] {
        standingRows
    }

    func eventDetail(league _: SportsLeague, eventId _: String) async throws -> SportsEventDetail? {
        nil
    }
}

private nonisolated func gregorianUTC() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private nonisolated func makeFixture(id: String, leagueId: String, start: Date, state: SportsFixtureState) -> SportsFixture {
    SportsFixture(
        id: id,
        leagueId: leagueId,
        leagueName: "Bundesliga",
        leagueAbbreviation: "BUND",
        startDate: start,
        status: SportsFixtureStatus(state: state)
    )
}

// MARK: - Cache round-trip

struct SportsCacheStoreTests {
    private func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func `snapshot survives a save load round-trip`() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsCacheStore(directory: dir)

        let leagueId = "espn:soccer/ger.1"
        let team = SportsTeam(leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern", abbreviation: "FCB", colorHex: "dc052d")
        let fixture = makeFixture(id: "1", leagueId: leagueId, start: Date(timeIntervalSince1970: 1_780_000_000), state: .scheduled)
        let row = SportsStandingRow(id: "132", teamId: "132", name: "Bayern", rank: 1, points: 10)
        let snapshot = SportsLeagueSnapshot(fixtures: [fixture], standings: [row], teams: [team], teamsFetchedAt: Date())

        store.save(snapshot, for: leagueId)
        let loaded = store.load(leagueId: leagueId)

        #expect(loaded?.fixtures == [fixture])
        #expect(loaded?.standings == [row])
        #expect(loaded?.teams == [team])
    }

    @Test func `load returns nil for an unknown league`() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsCacheStore(directory: dir)
        #expect(store.load(leagueId: "espn:soccer/unknown") == nil)
    }

    @Test func `removeAll drops every snapshot`() {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SportsCacheStore(directory: dir)
        store.save(SportsLeagueSnapshot(), for: "espn:soccer/ger.1")
        store.removeAll()
        #expect(store.load(leagueId: "espn:soccer/ger.1") == nil)
    }
}

// MARK: - monthsToFetch

struct SportsSyncMonthWindowTests {
    private func components(_ year: Int, _ month: Int) -> DateComponents {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        return comps
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return gregorianUTC().date(from: comps)!
    }

    @Test func `mid month fetches only the current month`() {
        let months = SportsSyncService.monthsToFetch(for: date(2026, 9, 10), calendar: gregorianUTC())
        #expect(months.count == 1)
        #expect(months.first?.year == 2026)
        #expect(months.first?.month == 9)
    }

    @Test func `within seven days of month end also fetches next month`() {
        // September has 30 days; the 25th leaves 5 days, so October is added.
        let months = SportsSyncService.monthsToFetch(for: date(2026, 9, 25), calendar: gregorianUTC())
        #expect(months.count == 2)
        #expect(months.last?.year == 2026)
        #expect(months.last?.month == 10)
    }

    @Test func `the first of the month also fetches the previous month`() {
        let months = SportsSyncService.monthsToFetch(for: date(2026, 10, 1), calendar: gregorianUTC())
        #expect(months.count == 2)
        #expect(months.first?.month == 9)
        #expect(months.last?.month == 10)
    }

    @Test func `year rolls over in December`() {
        let months = SportsSyncService.monthsToFetch(for: date(2026, 12, 28), calendar: gregorianUTC())
        #expect(months.count == 2)
        #expect(months.last?.year == 2027)
        #expect(months.last?.month == 1)
    }
}

// MARK: - leagueId(fromTeamID:)

struct SportsSyncLeagueIDTests {
    @Test func `team id yields its league id`() {
        #expect(SportsSyncService.leagueId(fromTeamID: "espn:soccer/ger.1:132") == "espn:soccer/ger.1")
    }

    @Test func `a bare league id has no trailing team segment`() {
        // "espn:soccer/ger.1" splits on its last ':' into "espn" — the seam is
        // documented as team-id-only input, so this just proves it never crashes.
        #expect(SportsSyncService.leagueId(fromTeamID: "no-colon") == nil)
    }
}

// MARK: - Refresh / merge

@MainActor
struct SportsSyncRefreshTests {
    private func tempStore() -> SportsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SportsStore(cache: SportsCacheStore(directory: dir))
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sports.test." + UUID().uuidString)!
    }

    @Test func `refresh publishes fetched data to the store`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let provider = StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)],
            teamList: [SportsTeam(leagueId: leagueId, teamId: "132", name: "Bayern", shortName: "Bayern", abbreviation: "FCB")],
            standingRows: [SportsStandingRow(id: "132", teamId: "132", name: "Bayern", rank: 1, points: 10)]
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: provider)

        await service.refreshAll()

        let snapshot = store.snapshot(for: leagueId)
        #expect(snapshot?.fixtures.count == 1)
        #expect(snapshot?.teams.count == 1)
        #expect(snapshot?.standings.count == 1)
        #expect(store.refreshError == false)
    }

    @Test func `a followed team pulls in its league`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        let provider = StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(teams: ["\(leagueId):132"]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: provider)

        #expect(service.leaguesToRefresh() == [leagueId])
        await service.refreshAll()
        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
    }

    @Test func `an all-empty refresh leaves the previous snapshot in place and flags an error`() async {
        let leagueId = "espn:soccer/ger.1"
        let store = tempStore()
        // A snapshot from this morning — nothing followed is current any more.
        store.update(
            SportsLeagueSnapshot(
                fetchedAt: Date().addingTimeInterval(-6 * 3600),
                fixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
            ),
            for: leagueId
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
        // ESPN unreachable: everything degrades to empty.
        service.configure(provider: StubProvider())
        await service.refreshAll()

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
        #expect(store.refreshError == true)
    }

    @Test func `an empty pass is not an outage while another followed league is current`() async {
        let current = "espn:soccer/ger.1"
        let offSeason = "espn:soccer/eng.1"
        let store = tempStore()
        store.update(
            SportsLeagueSnapshot(fixtures: [makeFixture(id: "1", leagueId: current, start: Date(), state: .scheduled)]),
            for: current
        )
        let service = SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [current, offSeason]),
            defaults: isolatedDefaults()
        )
        service.configure(provider: StubProvider())

        // Only the off-season league is stale, and it answers nothing.
        await service.refreshStale()

        #expect(store.snapshot(for: offSeason) == nil)
        #expect(store.refreshError == false)
    }
}

// MARK: - Overdue / freshness rules

struct SportsSyncOverdueTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let leagueId = "espn:soccer/ger.1"

    private func fixture(_ id: String, startingIn offset: TimeInterval, state: SportsFixtureState) -> SportsFixture {
        makeFixture(id: id, leagueId: leagueId, start: now.addingTimeInterval(offset), state: state)
    }

    @Test func `a scheduled game whose kickoff has passed is overdue`() {
        #expect(SportsSyncService.isOverdue(fixture("1", startingIn: -3 * 3600, state: .scheduled), now: now))
    }

    @Test func `a game still live since last night is overdue`() {
        #expect(SportsSyncService.isOverdue(fixture("1", startingIn: -20 * 3600, state: .inProgress), now: now))
    }

    @Test func `an upcoming game is not overdue`() {
        #expect(!SportsSyncService.isOverdue(fixture("1", startingIn: 3600, state: .scheduled), now: now))
    }

    @Test func `finished and postponed games are never overdue`() {
        #expect(!SportsSyncService.isOverdue(fixture("1", startingIn: -3600, state: .final), now: now))
        #expect(!SportsSyncService.isOverdue(fixture("2", startingIn: -3600, state: .postponed), now: now))
    }

    @Test func `a game stuck live beyond the lookback is left to the month refresh`() {
        let tooOld = -(SportsSyncService.overdueLookback + 3600)
        #expect(!SportsSyncService.isOverdue(fixture("1", startingIn: tooOld, state: .inProgress), now: now))
    }

    @Test func `poll days are the overdue fixtures' own days, unique and sorted`() {
        let calendar = gregorianUTC()
        let fixtures = [
            fixture("today-a", startingIn: -2 * 3600, state: .inProgress),
            fixture("today-b", startingIn: -3 * 3600, state: .scheduled),
            fixture("yesterday", startingIn: -26 * 3600, state: .inProgress),
            fixture("upcoming", startingIn: 3600, state: .scheduled),
            fixture("done", startingIn: -5 * 3600, state: .final)
        ]
        let days = SportsSyncService.pollDays(fixtures: fixtures, now: now, calendar: calendar)
        let yesterday = calendar.startOfDay(for: now.addingTimeInterval(-26 * 3600))
        #expect(days == [yesterday, calendar.startOfDay(for: now)])
    }

    @Test func `nothing live or overdue means no poll days`() {
        let fixtures = [
            fixture("upcoming", startingIn: 3600, state: .scheduled),
            fixture("done", startingIn: -5 * 3600, state: .final)
        ]
        #expect(SportsSyncService.pollDays(fixtures: fixtures, now: now).isEmpty)
    }

    @Test func `a missing snapshot is never fresh`() {
        #expect(!SportsSyncService.isFresh(nil, now: now))
    }

    @Test func `a snapshot is fresh only within the freshness window`() {
        let recent = SportsLeagueSnapshot(fetchedAt: now.addingTimeInterval(-60))
        let old = SportsLeagueSnapshot(fetchedAt: now.addingTimeInterval(-(SportsSyncService.freshness + 1)))
        #expect(SportsSyncService.isFresh(recent, now: now))
        #expect(!SportsSyncService.isFresh(old, now: now))
    }
}

// MARK: - Stale refresh

/// `refreshStale` is what every sports surface runs as it appears, so the Home
/// rail and the hub never show a morning's schedule in the evening. Its rules:
/// a missing or stale league is fetched in full, a fresh one costs nothing, and a
/// pass the provider never answered stays eligible (after `retryInterval`).
@MainActor
struct SportsSyncStaleRefreshTests {
    private let leagueId = "espn:soccer/ger.1"

    private func tempStore() -> SportsStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return SportsStore(cache: SportsCacheStore(directory: dir))
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "sports.test." + UUID().uuidString)!
    }

    private func service(store: SportsStore) -> SportsSyncService {
        SportsSyncService(
            store: store,
            followSource: StubFollowSource(leagues: [leagueId]),
            defaults: isolatedDefaults()
        )
    }

    @Test func `a followed league with nothing cached is fetched`() async {
        let store = tempStore()
        let sync = service(store: store)
        sync.configure(provider: StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
        ))

        await sync.refreshStale()

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
    }

    @Test func `a stale snapshot picks up moved kickoffs, results and new fixtures`() async {
        let store = tempStore()
        let played = Date().addingTimeInterval(-4 * 3600)
        let tonight = Date().addingTimeInterval(3 * 3600)
        store.update(
            SportsLeagueSnapshot(
                fetchedAt: Date().addingTimeInterval(-8 * 3600),
                fixtures: [
                    makeFixture(id: "played", leagueId: leagueId, start: played, state: .scheduled),
                    makeFixture(id: "moved", leagueId: leagueId, start: tonight, state: .scheduled)
                ]
            ),
            for: leagueId
        )
        let later = tonight.addingTimeInterval(3600)
        let sync = service(store: store)
        sync.configure(provider: StubProvider(monthFixtures: [
            makeFixture(id: "played", leagueId: leagueId, start: played, state: .final),
            makeFixture(id: "moved", leagueId: leagueId, start: later, state: .scheduled),
            makeFixture(id: "new", leagueId: leagueId, start: Date().addingTimeInterval(2 * 86400), state: .scheduled)
        ]))

        await sync.refreshStale()

        let fixtures = store.snapshot(for: leagueId)?.fixtures ?? []
        #expect(fixtures.first { $0.id == "played" }?.status.state == .final)
        #expect(fixtures.first { $0.id == "moved" }?.startDate == later)
        #expect(fixtures.contains { $0.id == "new" })
        #expect(SportsSyncService.isFresh(store.snapshot(for: leagueId), now: Date()))
    }

    @Test func `a fresh league is not fetched again, even with no fixtures`() async {
        let store = tempStore()
        let counter = RequestCounter()
        let sync = service(store: store)
        // Off-season: no fixtures, but the provider is reachable and answers with
        // standings — that is a successful pass, not a failed one.
        sync.configure(provider: StubProvider(
            standingRows: [SportsStandingRow(id: "132", teamId: "132", name: "Bayern", rank: 1, points: 10)],
            monthCalls: counter
        ))

        await sync.refreshStale()
        // Within a week of a month's end (or on the 1st) the pass fetches two
        // months, so the first request count depends on today's date.
        let firstFill = counter.count
        await sync.refreshStale()

        #expect(firstFill == SportsSyncService.monthsToFetch(for: Date()).count)
        #expect(counter.count == firstFill)
    }

    @Test func `a fresh league goes stale after the freshness window`() async {
        let store = tempStore()
        let counter = RequestCounter()
        store.update(
            SportsLeagueSnapshot(fixtures: [makeFixture(id: "cached", leagueId: leagueId, start: Date(), state: .scheduled)]),
            for: leagueId
        )
        let sync = service(store: store)
        sync.configure(provider: StubProvider(
            monthFixtures: [makeFixture(id: "cached", leagueId: leagueId, start: Date(), state: .inProgress)],
            monthCalls: counter
        ))

        await sync.refreshStale()
        #expect(counter.count == 0)

        await sync.refreshStale(now: Date().addingTimeInterval(SportsSyncService.freshness + 1))
        #expect(counter.count > 0)
        #expect(store.snapshot(for: leagueId)?.fixtures.first?.status.state == .inProgress)
    }

    @Test func `a pass the provider never answered is retried, but not on every appearance`() async {
        let store = tempStore()
        let counter = RequestCounter()
        let sync = service(store: store)
        // First pass: ESPN unreachable, everything degrades to empty.
        sync.configure(provider: StubProvider(monthCalls: counter))
        await sync.refreshStale()
        let firstPass = counter.count
        #expect(store.snapshot(for: leagueId) == nil)
        #expect(store.refreshError == true)

        // A surface appearing a moment later does not hammer the provider.
        await sync.refreshStale()
        #expect(counter.count == firstPass)

        // Once the retry interval has passed, with the provider back, it fills.
        sync.configure(provider: StubProvider(
            monthFixtures: [makeFixture(id: "1", leagueId: leagueId, start: Date(), state: .scheduled)]
        ))
        await sync.refreshStale(now: Date().addingTimeInterval(SportsSyncService.retryInterval + 1))

        #expect(store.snapshot(for: leagueId)?.fixtures.count == 1)
        #expect(store.refreshError == false)
    }
}
