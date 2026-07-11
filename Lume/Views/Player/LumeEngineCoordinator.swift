import AVFoundation
import Combine
import Foundation
import LumeEngine
import OSLog
import SwiftUI

/// Holds the engine's active subtitle cue text, refreshed from the coordinator's
/// 10 Hz playback tick. Deliberately a separate `ObservableObject` from
/// `LumeEngineCoordinator`: were the cue text `@Published` on the coordinator,
/// every per-tick update would fire the coordinator's `objectWillChange` and
/// re-render every overlay that observes it — flickering an open audio/subtitle
/// `Menu` and cancelling in-flight taps. Only the subtitle-rendering leaf
/// observes this model, so a cue change invalidates that leaf alone. Mirrors why
/// KSPlayer keeps its `SubtitleModel` off the controls overlay's observed surface.
@MainActor
final class SubtitleCueModel: ObservableObject {
    @Published private(set) var text: String?

    /// Assigns only on an actual change, so an unchanged cue repeated across
    /// ticks doesn't invalidate the leaf ten times a second.
    func update(_ newText: String?) {
        if text != newText { text = newText }
    }
}

/// Playback surface for the LumeEngine (FFmpeg) backend.
///
/// Wraps a `PlayerSession` per stream — the engine has no rebuild-in-place, so
/// `configure`/`reload` always tear the old session down and build a fresh one
/// (which is exactly the semantics `FullScreenPlayerView` expects from
/// `.id(engineAttempt)` teardown). Mirrors the coordinator surface of
/// `AVPlayerCoordinator`/`VLCPlayerCoordinator` so overlays stay engine-agnostic.
@MainActor
final class LumeEngineCoordinator: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = false
    /// Set once the first frames are rendering; drives the loading indicator
    /// and the startup-failure watchdog.
    @Published private(set) var hasStartedPlayback = false
    @Published private(set) var videoInfo: PlayerVideoInfo?
    @Published private(set) var audioTrackOptions: [PlayerTrackOption] = []
    @Published private(set) var textTrackOptions: [PlayerTrackOption] = []
    @Published private(set) var isPipActive = false
    /// Active subtitle cue text, on its own observable so the 10 Hz tick that
    /// refreshes it doesn't invalidate this coordinator. A `@Published` here
    /// would fire `objectWillChange` on every tick, re-rendering every overlay
    /// that observes the coordinator (iOS `LumeEngineControlsOverlay`, tvOS
    /// `TVPlayerControlsOverlay`) — which flickers an open audio/subtitle `Menu`
    /// and cancels in-flight taps. Only the subtitle-rendering leaf observes
    /// this model, so a cue change invalidates that leaf alone.
    let subtitleCues = SubtitleCueModel()

    var isPipSupported: Bool {
        pipBridge?.isSupported ?? false
    }

    var playbackRate: Float = 1.0 {
        didSet {
            let session = session
            let rate = playbackRate
            Task { await session?.setRate(rate) }
        }
    }

    /// 10 Hz playback tick: (current, duration) in media-relative seconds.
    var onTime: ((TimeInterval, TimeInterval) -> Void)?
    /// Initial-load failure (hard error or startup timeout before first frame).
    var onPlaybackFailure: (() -> Void)?
    /// Mid-stream stall after playback had started (the engine's watchdog);
    /// the view routes this through `PlaybackRetryController`.
    var onStalled: (() -> Void)?
    /// Playback reached a healthy playing state — the view resets its
    /// reconnect budget.
    var onRecovered: (() -> Void)?
    var startupTimeout: TimeInterval = 40

    /// The engine's video surface for the hosting representable. Published:
    /// a seamless switch swaps it mid-flight and the surface must re-install.
    @Published private(set) var displayLayer: LumeDisplayLayer?

    private var session: PlayerSession?
    private var pipBridge: PictureInPictureBridge?
    private var mediaInfo: MediaInfo?
    private var currentMedia: PlayableMedia?
    private var eventTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    /// 10 Hz tick counter driving the diagnostics heartbeat cadence.
    private var tickCount = 0
    private var startupTask: Task<Void, Never>?
    private var reportedFailure = false
    private var selectedSubtitleID: String?

    // Zero-delay switching (engine PLAN.md §6). The standby session is staged
    // by `prepareNext` through first-frame-decoded; the generation counters
    // let superseded prepares/switches discard their session instead of
    // installing it (rapid channel zapping cancels in-flight switches).
    private var preparedNext: (url: String, session: PlayerSession, info: MediaInfo)?
    private var prepareGeneration = 0
    private var switchTask: Task<Void, Never>?
    private var switchGeneration = 0
    /// True while a replacement session is opening behind the still-playing
    /// one; gates the old session's stall/failure retries and the clock tick.
    private var switchInFlight = false

    // MARK: Lifecycle

    func configure(media: PlayableMedia) {
        // Zero-delay switching: while something is already on screen, keep it
        // playing while the replacement opens through its first decoded
        // frame, then swap the layers atomically. The cold teardown-first
        // path remains for the initial configure and when the option is off.
        if LumeEngineOptions.load().seamlessSwitching, session != nil, hasStartedPlayback {
            seamlessSwitch(to: media)
        } else {
            configureCold(media: media)
        }
    }

    private func configureCold(media: PlayableMedia) {
        tearDown()
        currentMedia = media
        reportedFailure = false

        let session = PlayerSession(configuration: makeConfiguration(for: media))
        self.session = session
        displayLayer = session.renderer.displayLayer
        session.renderer.audioTimePitchAlgorithm = .timeDomain

        eventTask = Task { [events = session.events] in
            for await event in events {
                self.handle(event: event)
            }
        }
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self.tick()
            }
        }
        startupTask = makeStartupWatchdog()

        Task {
            do {
                let info = try await session.open(url: media.url.absoluteString)
                self.mediaInfo = info
                self.publishTracks(info: info)
                self.publishVideoInfo(info: info)
                self.pipBridge = PictureInPictureBridge(session: session, mediaInfo: info)
                // Resume position is handled by the engine via
                // configuration.startPosition (seek-before-first-read).
                if media.startTime > 1, !media.isLive, !info.isSeekable {
                    Logger.player.warning("LumeEngine cannot resume: source is not seekable")
                }
                await session.play()
            } catch {
                self.reportFailure()
            }
        }
    }

    /// Startup failure watchdog. The window is rolling while the engine
    /// demonstrably downloads: a multi-second buffer target on a ~1× link
    /// legitimately pre-buffers past any fixed window, while a dead stream
    /// shows no byte progress and still fails within `startupTimeout`. A hard
    /// cap bounds pathological "downloads but never starts" cases.
    private func makeStartupWatchdog() -> Task<Void, Never> {
        Task { [startupTimeout] in
            let hardDeadline = Date(timeIntervalSinceNow: max(startupTimeout * 3, 60))
            var deadline = Date(timeIntervalSinceNow: startupTimeout)
            var lastBytes: Int64 = 0
            while !Task.isCancelled, !self.hasStartedPlayback {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, !self.hasStartedPlayback else { return }
                if let session = self.session {
                    let bytes = await session.diagnostics.deliveredBytes
                    if bytes > lastBytes {
                        lastBytes = bytes
                        deadline = min(Date(timeIntervalSinceNow: startupTimeout), hardDeadline)
                    }
                }
                if Date() >= deadline {
                    Logger.player.error("LumeEngine startup window elapsed (read \(lastBytes) bytes, never played)")
                    self.reportFailure()
                    return
                }
            }
        }
    }

    /// Fresh session for the same stream (stall recovery), resuming from the
    /// current position for VOD. Always the cold path: the stalled session's
    /// connection must be released before re-opening the same URL — providers
    /// that cap concurrent connections refuse a second stream of it.
    func reload() {
        guard var media = currentMedia else { return }
        if media.kind == .vod, let session {
            let resumeAt = sessionPositionSnapshot(session)
            media = media.resuming(at: resumeAt)
        }
        configureCold(media: media)
    }

    func tearDown() {
        switchGeneration += 1
        switchTask?.cancel()
        switchTask = nil
        switchInFlight = false
        discardPreparedNext()
        eventTask?.cancel()
        tickTask?.cancel()
        startupTask?.cancel()
        eventTask = nil
        tickTask = nil
        startupTask = nil
        pipBridge = nil
        if let session {
            Task { await session.shutdown() }
        }
        session = nil
        mediaInfo = nil
        displayLayer = nil
        isPlaying = false
        isBuffering = false
        hasStartedPlayback = false
        subtitleCues.update(nil)
        isPipActive = false
    }

    // MARK: Transport

    func togglePlay() {
        let session = session
        let playing = isPlaying
        Task {
            if playing {
                await session?.pause()
            } else {
                await session?.play()
            }
        }
    }

    func skip(by seconds: Double) {
        let session = session
        Task {
            guard let session else { return }
            let position = await session.position
            await session.seek(to: max(0, position + seconds))
        }
    }

    func seek(to seconds: TimeInterval) {
        let session = session
        Task { await session?.seek(to: seconds) }
    }

    func togglePictureInPicture() {
        pipBridge?.toggle()
        isPipActive = pipBridge?.isActive ?? false
    }

    // MARK: Tracks

    func selectAudioTrack(id: String) {
        guard let index = Int32(id) else { return }
        let session = session
        Task { await session?.selectAudioTrack(index) }
        if let info = mediaInfo {
            publishTracks(info: info, selectedAudioID: id)
        }
    }

    func selectTextTrack(id: String?) {
        selectedSubtitleID = id
        let session = session
        let index = id.flatMap(Int32.init)
        Task { await session?.selectSubtitleTrack(index) }
        if id == nil { subtitleCues.update(nil) }
        if let info = mediaInfo {
            publishTracks(info: info)
        }
    }

    // MARK: Internals

    /// Builds the session configuration from the stored Lume Engine options
    /// (Settings → Lume Engine Options), re-read on every configure/reload.
    private func makeConfiguration(for media: PlayableMedia) -> PlayerConfiguration {
        let options = LumeEngineOptions.load()
        var configuration = PlayerConfiguration()
        // Resume position goes through the engine (seek-before-first-read):
        // an open-then-seek from here seeks a connection that is already
        // streaming, which some IPTV providers kill (dead stream, no data).
        if media.startTime > 1, !media.isLive {
            configuration.startPosition = media.startTime
        }
        configuration.hardwareDecode = options.hardwareDecode ? .videoToolbox : .software
        configuration.seamlessSwitching = options.seamlessSwitching
        configuration.bufferTarget = Double(media.isLive ? options.liveBuffer : options.vodBuffer) / 1000
        configuration.videoQueueDepth = options.videoQueueDepth
        configuration.audioQueueDepth = options.audioQueueDepth
        configuration.stallThreshold = Double(options.stallThreshold)
        configuration.demuxer.enableReconnect = options.httpReconnect
        configuration.demuxer.ioTimeout = options.ioTimeout
        // The open timeout stays tied to the engine-fallback budget rather than
        // a user option, so the fallback chain keeps its timing guarantees.
        configuration.demuxer.openTimeout = startupTimeout
        if let probeSize = options.probeSize {
            configuration.demuxer.probeSize = probeSize
        }
        if let analyzeDuration = options.analyzeDuration {
            configuration.demuxer.maxAnalyzeDuration = analyzeDuration
        }
        return configuration
    }

    private func handle(event: PlayerEvent) {
        switch event {
        case let .stateChanged(state):
            handleStateChange(state)
        case let .stalled(position):
            Logger.player.warning("LumeEngine stalled at \(position, format: .fixed(precision: 2))s")
            guard !switchInFlight else { break }
            onStalled?()
        case let .error(error):
            Logger.player.error("LumeEngine error: \(String(describing: error), privacy: .public)")
        case let .didSeek(position):
            Logger.player.info("LumeEngine didSeek → \(position, format: .fixed(precision: 2))s")
        case let .decoderDowngraded(error):
            Logger.player.warning("LumeEngine decoder downgraded: \(String(describing: error), privacy: .public)")
        case .opened:
            break
        }
    }

    private func handleStateChange(_ state: PlayerSession.State) {
        Logger.player.info("LumeEngine state → \(String(describing: state), privacy: .public)")
        isPlaying = state == .playing
        isBuffering = state == .buffering || state == .opening
        if state == .playing {
            hasStartedPlayback = true
            onRecovered?()
        }
        if state == .failed {
            // Local copy: os_log's autoclosure needs explicit self for the
            // property, which swiftformat's redundantSelf keeps stripping.
            let started = hasStartedPlayback
            Logger.player.error("LumeEngine failed (hasStartedPlayback: \(started))")
            if switchInFlight {
                // The outgoing session died while its replacement is
                // already opening — the switch supersedes any retry.
            } else if started {
                onStalled?()
            } else {
                reportFailure()
            }
        }
    }

    private func tick() async {
        guard let session else { return }
        let position = await session.position
        let duration = await session.duration ?? 0
        // While a replacement is opening, the ticking session is the outgoing
        // one — its position must not leak into the new stream's clock (the
        // view already reset it for the incoming media). Subtitles keep
        // updating: the outgoing video is still what's on screen.
        if !switchInFlight {
            onTime?(position, duration)
        }

        // Pipeline-health heartbeat: every ~3 s until playback settles, then
        // every ~30 s. Ground truth for triaging device-only failures (silent
        // audio, wedged buffering, throttled delivery) from a sysdiagnose or
        // Console stream without a debugger.
        tickCount += 1
        let heartbeatEvery = hasStartedPlayback && isPlaying ? 300 : 30
        if tickCount % heartbeatEvery == 0 {
            let diagnostics = await session.diagnostics
            Logger.player.info("LumeEngine \(diagnostics.description, privacy: .public)")
        }

        let now = session.renderer.currentTime
        if now != .min {
            let cues = session.subtitles.activeCues(at: now)
            let text = cues.map(\.text).joined(separator: "\n")
            subtitleCues.update(text.isEmpty ? nil : text)
        }
    }

    private func publishTracks(info: MediaInfo, selectedAudioID: String? = nil) {
        audioTrackOptions = info.audioTracks.enumerated().map { position, track in
            let id = String(track.index)
            let fallbackSelected = selectedAudioID == nil && position == 0
            return PlayerTrackOption(
                id: id,
                label: trackLabel(track, fallback: "Audio \(position + 1)"),
                isSelected: selectedAudioID.map { $0 == id } ?? fallbackSelected
            )
        }
        textTrackOptions = info.subtitleTracks.enumerated().map { position, track in
            let id = String(track.index)
            return PlayerTrackOption(
                id: id,
                label: trackLabel(track, fallback: "Subtitle \(position + 1)"),
                isSelected: selectedSubtitleID == id
            )
        }
    }

    private func publishVideoInfo(info: MediaInfo) {
        guard let track = info.videoTracks.first, let video = track.video else { return }
        videoInfo = PlayerVideoInfo(
            width: video.width,
            height: video.height,
            fps: video.fps,
            codec: track.codecName
        )
    }

    private func trackLabel(_ track: TrackInfo, fallback: String) -> String {
        if let title = track.title, !title.isEmpty { return title }
        if let language = track.language, !language.isEmpty {
            return Locale.current.localizedString(forLanguageCode: language) ?? language
        }
        return fallback
    }

    private func reportFailure() {
        guard !reportedFailure else { return }
        reportedFailure = true
        onPlaybackFailure?()
    }

    private func sessionPositionSnapshot(_ session: PlayerSession) -> TimeInterval {
        let now = session.renderer.currentTime
        guard let info = mediaInfo, now != .min else { return 0 }
        return max(0, MediaTime.seconds(now - info.startTime))
    }
}

// MARK: - Zero-delay switching

/// The seamless-switch machinery. The stored state it drives
/// (`preparedNext`, the generation counters, `switchInFlight`) lives with
/// the class; the methods sit here in a same-file extension.
extension LumeEngineCoordinator {
    /// Stages the next stream (the queued episode) in a standby session,
    /// opened through first-frame-decoded but never played. A later
    /// `configure` for the same URL swaps it in with zero delay. No-op when
    /// seamless switching is off or the URL is already staged.
    func prepareNext(media: PlayableMedia) {
        guard LumeEngineOptions.load().seamlessSwitching else { return }
        let url = media.url.absoluteString
        guard preparedNext?.url != url else { return }
        discardPreparedNext()
        let generation = prepareGeneration

        Logger.player.info("LumeEngine preparing next stream through first frame")
        let standby = PlayerSession(configuration: makeConfiguration(for: media))
        standby.renderer.audioTimePitchAlgorithm = .timeDomain
        Task {
            do {
                let info = try await standby.open(url: url)
                await standby.waitForFirstFrame(timeout: 10)
                guard generation == self.prepareGeneration else {
                    await standby.shutdown()
                    return
                }
                self.preparedNext = (url: url, session: standby, info: info)
                Logger.player.info("LumeEngine next stream prepared")
            } catch {
                Logger.player.warning("LumeEngine prepare-next failed: \(String(describing: error), privacy: .public)")
                await standby.shutdown()
            }
        }
    }

    /// Opens `media` behind the still-playing session and swaps atomically
    /// once the replacement holds its first decoded frame — the screen never
    /// goes black. Consumes a staged standby when the URL matches. On failure
    /// it falls back to the cold path (which also covers providers that
    /// refuse a second concurrent connection: teardown-first frees the slot).
    private func seamlessSwitch(to media: PlayableMedia) {
        switchGeneration += 1
        let generation = switchGeneration
        switchTask?.cancel()
        switchInFlight = true
        currentMedia = media
        reportedFailure = false
        isBuffering = true // spinner over the still-playing outgoing stream

        // Consume a matching standby; discard one staged for another URL.
        let staged: (url: String, session: PlayerSession, info: MediaInfo)?
        if let prepared = preparedNext, prepared.url == media.url.absoluteString {
            staged = prepared
            preparedNext = nil
            prepareGeneration += 1 // supersede any in-flight prepare
        } else {
            staged = nil
            discardPreparedNext()
        }

        switchTask = Task {
            var replacement: (session: PlayerSession, info: MediaInfo)?
            if let staged, await staged.session.state != .failed {
                replacement = (staged.session, staged.info)
            } else {
                if let staged { await staged.session.shutdown() }
                let session = PlayerSession(configuration: self.makeConfiguration(for: media))
                session.renderer.audioTimePitchAlgorithm = .timeDomain
                do {
                    let info = try await session.open(url: media.url.absoluteString)
                    await session.waitForFirstFrame(timeout: 10)
                    replacement = (session, info)
                } catch {
                    Logger.player.warning("LumeEngine seamless open failed: \(String(describing: error), privacy: .public)")
                    await session.shutdown()
                }
            }

            guard !Task.isCancelled, generation == self.switchGeneration else {
                // Superseded by a newer switch or teardown — discard quietly.
                if let session = replacement?.session {
                    Task { await session.shutdown() }
                }
                return
            }
            guard let replacement else {
                Logger.player.warning("LumeEngine seamless switch failed → cold reload")
                self.switchInFlight = false
                self.configureCold(media: media)
                return
            }
            self.adopt(session: replacement.session, info: replacement.info)
        }
    }

    /// The atomic swap: the replacement (already holding its first frame)
    /// becomes the active session, its layer replaces the outgoing one, and
    /// the old session tears down asynchronously — never blocking the swap on
    /// data-plane thread joins.
    private func adopt(session next: PlayerSession, info: MediaInfo) {
        eventTask?.cancel()
        tickTask?.cancel()
        startupTask?.cancel()
        if let old = session {
            Task { await old.shutdown() }
        }
        switchInFlight = false
        session = next
        mediaInfo = info
        displayLayer = next.renderer.displayLayer
        selectedSubtitleID = nil
        subtitleCues.update(nil)
        hasStartedPlayback = false
        isPipActive = false
        publishTracks(info: info)
        publishVideoInfo(info: info)
        pipBridge = PictureInPictureBridge(session: next, mediaInfo: info)

        eventTask = Task { [events = next.events] in
            for await event in events {
                self.handle(event: event)
            }
        }
        tickTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self.tick()
            }
        }
        startupTask = makeStartupWatchdog()

        let rate = playbackRate
        Task {
            if rate != 1.0 { await next.setRate(rate) }
            await next.play()
        }
    }

    private func discardPreparedNext() {
        prepareGeneration += 1
        guard let prepared = preparedNext else { return }
        preparedNext = nil
        Task { await prepared.session.shutdown() }
    }
}

#if os(tvOS)
    /// The shared Apple TV overlay drives LumeEngine through the same surface
    /// as every other engine. All requirements already exist with matching
    /// signatures, so the conformance is empty.
    extension LumeEngineCoordinator: TVPlaybackEngine {}
#endif
