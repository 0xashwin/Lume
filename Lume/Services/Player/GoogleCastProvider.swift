import Foundation
import OSLog

// Chromecast is delivered through the Google Cast SDK (v4.8.4), an iOS-only
// dependency bundled at `Vendor/GoogleCast` and linked with `platformFilter =
// ios` (see `Docs/Chromecast.md`). This file is gated behind
// `os(iOS) && canImport(GoogleCast)` so the macOS/tvOS/visionOS builds never
// compile it. `CastService.configureGoogleCast()` registers this provider on the
// `CastProvider` seam and the overlay's Chromecast button comes to life.

#if os(iOS) && canImport(GoogleCast)
    import GoogleCast

    /// Bridges the Google Cast SDK to the engine-agnostic `CastProvider` seam.
    ///
    /// Device discovery and session start/stop are driven by the system
    /// `GCKUICastButton` (see `ChromecastButton`); this type listens for the
    /// resulting session, loads the current `PlayableMedia` onto the receiver,
    /// and exposes the receiver's transport (play/pause/seek + polled
    /// position/state) for `ChromecastPlaybackView`, which takes the local
    /// engine's place while the session is active (#103).
    @MainActor
    final class GoogleCastProvider: NSObject, CastProvider {
        /// Reports session start/end. `CastService` mirrors this into its
        /// observable `isProviderCasting` so the player UI can react (this
        /// class is not `@Observable`).
        var onCastingChanged: ((Bool) -> Void)?

        private(set) var isCasting = false {
            didSet { if isCasting != oldValue { onCastingChanged?(isCasting) } }
        }

        var connectedDeviceName: String? {
            sessionManager.currentCastSession?.device.friendlyName
        }

        /// Media queued to load as soon as a session is available — set when the
        /// user starts casting before a receiver has finished connecting.
        private var pendingMedia: (media: PlayableMedia, position: TimeInterval)?

        /// URL of the stream this provider last loaded onto the current session,
        /// so `beginSession` can no-op when asked to cast what is already
        /// playing (the host re-invokes it on every "may have changed" edge).
        private var loadedURL: URL?

        private var sessionManager: GCKSessionManager {
            GCKCastContext.sharedInstance().sessionManager
        }

        private var remoteMediaClient: GCKRemoteMediaClient? {
            sessionManager.currentCastSession?.remoteMediaClient
        }

        override init() {
            super.init()
            sessionManager.add(self)
        }

        deinit {
            // `GCKCastContext` is a shared singleton; drop our listener so a
            // re-created provider doesn't double-handle session callbacks.
            GCKCastContext.sharedInstance().sessionManager.remove(self)
        }

        // MARK: - CastProvider

        func beginSession(for media: PlayableMedia, startingAt position: TimeInterval) {
            if let client = remoteMediaClient {
                guard media.url != loadedURL else { return }
                load(media, at: position, on: client)
            } else {
                // No receiver yet — remember the media and load once a session
                // starts (the user is mid-connect via the cast button).
                pendingMedia = (media, position)
            }
        }

        func endSession() {
            pendingMedia = nil
            sessionManager.endSessionAndStopCasting(true)
        }

        // MARK: - Transport

        var approximatePosition: TimeInterval {
            guard let client = remoteMediaClient, client.mediaStatus != nil else { return 0 }
            let position = client.approximateStreamPosition()
            return position.isFinite ? max(position, 0) : 0
        }

        var streamDuration: TimeInterval {
            let duration = remoteMediaClient?.mediaStatus?.mediaInformation?.streamDuration ?? 0
            return duration.isFinite ? max(duration, 0) : 0
        }

        var isReceiverPlaying: Bool {
            // Buffering/loading count as playing: the receiver will resume by
            // itself, so the button should keep offering "pause" rather than
            // flickering to "play" on every rebuffer.
            switch remoteMediaClient?.mediaStatus?.playerState {
            case .playing, .buffering, .loading: true
            default: false
            }
        }

        func play() {
            remoteMediaClient?.play()
        }

        func pause() {
            remoteMediaClient?.pause()
        }

        func seek(to seconds: TimeInterval) {
            let options = GCKMediaSeekOptions()
            options.interval = seconds
            options.resumeState = .unchanged
            remoteMediaClient?.seek(with: options)
        }

        // MARK: - Loading

        private func load(_ media: PlayableMedia, at position: TimeInterval, on client: GCKRemoteMediaClient) {
            let metadata = GCKMediaMetadata(metadataType: media.isLive ? .generic : .movie)
            metadata.setString(media.title, forKey: kGCKMetadataKeyTitle)
            if let subtitle = media.subtitle, !subtitle.isEmpty {
                metadata.setString(subtitle, forKey: kGCKMetadataKeySubtitle)
            }
            if let posterURL = media.posterURL {
                metadata.addImage(GCKImage(url: posterURL, width: 480, height: 720))
            }

            let infoBuilder = GCKMediaInformationBuilder(contentURL: media.url)
            infoBuilder.streamType = media.isLive ? .live : .buffered
            infoBuilder.contentType = Self.contentType(for: media.url)
            infoBuilder.metadata = metadata

            let requestBuilder = GCKMediaLoadRequestDataBuilder()
            requestBuilder.mediaInformation = infoBuilder.build()
            requestBuilder.startTime = media.isLive ? kGCKInvalidTimeInterval : position

            client.loadMedia(with: requestBuilder.build())
            loadedURL = media.url
            Logger.player.log("Chromecast: loading media live=\(media.isLive, privacy: .public)")
        }

        /// Best-effort MIME type from the URL extension; HLS is the common IPTV
        /// case, so default to it when the container is unknown.
        private static func contentType(for url: URL) -> String {
            switch url.pathExtension.lowercased() {
            case "mp4", "m4v": "video/mp4"
            case "mkv": "video/x-matroska"
            case "ts": "video/mp2t"
            default: "application/x-mpegurl"
            }
        }
    }

    // MARK: - GCKSessionManagerListener

    extension GoogleCastProvider: GCKSessionManagerListener {
        func sessionManager(_: GCKSessionManager, didStart session: GCKCastSession) {
            loadedURL = nil
            isCasting = true
            Logger.player.log("Chromecast: session started")
            if let pending = pendingMedia, let client = session.remoteMediaClient {
                load(pending.media, at: pending.position, on: client)
                pendingMedia = nil
            }
        }

        func sessionManager(_: GCKSessionManager, didResumeCastSession _: GCKCastSession) {
            isCasting = true
        }

        func sessionManager(_: GCKSessionManager, didEnd _: GCKCastSession, withError error: Error?) {
            loadedURL = nil
            pendingMedia = nil
            isCasting = false
            if let error {
                Logger.player.error("Chromecast: session ended with error: \(error.localizedDescription, privacy: .public)")
            }
        }

        func sessionManager(_: GCKSessionManager, didFailToStart _: GCKCastSession, withError error: Error) {
            // The connect attempt died — don't leave the queued media around to
            // auto-load onto some later, unrelated session.
            loadedURL = nil
            pendingMedia = nil
            isCasting = false
            Logger.player.error("Chromecast: session failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }
#endif
