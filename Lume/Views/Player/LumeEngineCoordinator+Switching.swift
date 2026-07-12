//
//  LumeEngineCoordinator+Switching.swift
//  Lume
//
//  Zero-delay stream switching for the Lume Engine (engine PLAN.md §6): a
//  replacement session opens through its first decoded frame before the
//  display layers swap atomically, so channel zaps and episode changes never
//  show a black gap. Connection-aware: the overlapped variant (old stream
//  keeps playing) runs only when the provider allows a second concurrent
//  connection; otherwise the sequential variant closes the outgoing stream
//  first and freezes its last frame — never more than one provider
//  connection at a time. The stored state these methods drive, and the swap
//  itself (`adopt`), live on the class in LumeEngineCoordinator.swift.
//

import AVFoundation
import Foundation
import LumeEngine
import OSLog

extension LumeEngineCoordinator {
    /// Whether a second stream may be opened beside the playing one.
    /// Different providers never contend for the same connection cap, and
    /// local files hold no connection at all; the same provider must be
    /// known to allow at least two concurrent connections (the playlist's
    /// `max_connections`). Unknown caps (m3u, stalker, panels reporting "0")
    /// count as one — a wrong overlap can kill both streams, while a
    /// sequential switch only costs the moving picture during the switch.
    func overlapAllowed(with media: PlayableMedia) -> Bool {
        guard let current = currentMedia else { return true }
        if current.url.isFileURL || media.url.isFileURL { return true }
        if let currentProvider = current.playlistID, let nextProvider = media.playlistID,
           currentProvider != nextProvider { return true }
        return (media.maxConnections ?? 1) >= 2
    }

    /// Stages the next stream (the queued episode) in a standby session,
    /// opened through first-frame-decoded but never played. A later
    /// `configure` for the same URL swaps it in with zero delay. No-op when
    /// seamless switching is off, the standby's connection would exceed the
    /// provider's cap, or the URL is already staged.
    func prepareNext(media: PlayableMedia) {
        guard LumeEngineOptions.load().seamlessSwitching else { return }
        // The standby holds its own provider connection beside the playing
        // stream — exactly the overlapped budget.
        guard overlapAllowed(with: media) else { return }
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
    /// goes black. Consumes a staged standby when the URL matches. Requires
    /// the overlapped connection budget (`overlapAllowed`); on failure it
    /// retries sequentially, which frees the outgoing connection first.
    func seamlessSwitch(to media: PlayableMedia) {
        let generation = beginSwitch(to: media)

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
                    Logger.player.warning("LumeEngine overlapped open failed: \(String(describing: error), privacy: .public)")
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
                // The overlapped open was refused or died — e.g. the account
                // is streaming elsewhere and the cap is exhausted. Retry
                // sequentially: closing the current stream first frees the
                // slot, and its frozen frame keeps the screen alive.
                Logger.player.warning("LumeEngine overlapped switch failed → sequential retry")
                self.sequentialSwitch(to: media)
                return
            }
            self.adopt(session: replacement.session, info: replacement.info)
        }
    }

    /// Single-connection switch: the outgoing session shuts down *first*
    /// (releasing its provider connection) while its display layer stays up,
    /// frozen on the last decoded frame — the engine flushes without removing
    /// the displayed image — then the replacement opens and the layers swap
    /// at its first frame. At most one provider connection exists at any
    /// moment; playback pauses for the duration of the open, but the screen
    /// never goes black.
    func sequentialSwitch(to media: PlayableMedia) {
        let generation = beginSwitch(to: media)
        // A staged standby holds the very connection this switch needs free.
        discardPreparedNext()

        // Stop mirroring the outgoing session; `displayLayer` deliberately
        // keeps pointing at its layer until the replacement is ready.
        let outgoing = detachOutgoingSession()

        switchTask = Task {
            // Bounded join: the connection must actually be closed before the
            // new open, or a one-connection provider refuses it.
            if let outgoing { await outgoing.shutdown() }

            let replacement = PlayerSession(configuration: self.makeConfiguration(for: media))
            replacement.renderer.audioTimePitchAlgorithm = .timeDomain
            do {
                let info = try await replacement.open(url: media.url.absoluteString)
                await replacement.waitForFirstFrame(timeout: 10)
                guard !Task.isCancelled, generation == self.switchGeneration else {
                    await replacement.shutdown()
                    return
                }
                self.adopt(session: replacement, info: info)
            } catch {
                Logger.player.warning("LumeEngine sequential switch failed: \(String(describing: error), privacy: .public)")
                await replacement.shutdown()
                guard !Task.isCancelled, generation == self.switchGeneration else { return }
                // The outgoing stream is already gone; retry once through the
                // cold path, whose watchdog and failure reporting take over.
                self.configureCold(media: media)
            }
        }
    }
}
