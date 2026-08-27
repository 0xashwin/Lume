//
//  KSPlayerEngineView+Options.swift
//  Lume
//
//  Builds the `KSOptions` for a playback session from the user's saved KSPlayer
//  settings (see `KSPlayerOptions`). Split out of `KSPlayerEngineView` to keep
//  that view file focused on the SwiftUI body.
//

import Foundation
import KSPlayer
import SwiftUI

/// Turns the user's saved KSPlayer settings into a `KSOptions` for one stream.
/// Shared by the full-screen engine view and the Multi-View tiles, which need
/// the same decoder/buffer tuning but must not claim Picture in Picture.
enum KSPlayerOptionsFactory {
    /// Process-wide KSPlayer configuration, applied exactly once on first
    /// access (static `let` init is lazy and thread-safe). These are global
    /// settings, so assigning them on every `make` call was a needless side
    /// effect from a view body.
    static let configureGlobalOptions: Void = {
        KSOptions.secondPlayerType = KSMEPlayer.self
        KSOptions.isAutoPlay = true
        KSOptions.isPipPopViewController = false

        #if DEBUG
            KSOptions.logLevel = .warning
        #else
            KSOptions.logLevel = .error
        #endif
    }()

    /// - Parameter allowsPictureInPicture: `false` for a Multi-View tile — four
    ///   tiles each allowed to start PiP from inline would fight over the one
    ///   PiP window.
    static func make(for media: PlayableMedia, allowsPictureInPicture: Bool = true) -> KSOptions {
        _ = configureGlobalOptions

        let settings = KSPlayerOptions.load()
        // System-proxy use and the primary engine are process-wide statics with
        // no per-instance counterpart, so they're applied on the type each time.
        // The layer reads `firstPlayerType` when it's created (in the view body),
        // so setting it here takes effect for this playback.
        KSOptions.useSystemHTTPProxy = settings.systemProxy
        KSOptions.firstPlayerType = settings.primaryEngine == .ffmpeg ? KSMEPlayer.self : KSAVPlayer.self

        let options = KSOptions()
        // Now Playing metadata + remote commands are owned by
        // `NowPlayingService` for all engines; KSPlayer's built-in
        // registration would double-handle every command.
        options.registerRemoteControll = false
        options.hardwareDecode = settings.hardwareDecode
        options.asynchronousDecompression = settings.asyncDecompression
        options.isSecondOpen = settings.secondOpen
        options.isAccurateSeek = settings.accurateSeek
        options.isLoopPlay = settings.loopPlay
        options.autoDeInterlace = settings.autoDeinterlace
        options.autoRotate = settings.autoRotate
        options.videoAdaptable = settings.adaptive
        options.nobuffer = settings.noBuffer
        options.codecLowDelay = settings.codecLowDelay
        options.canStartPictureInPictureAutomaticallyFromInline = allowsPictureInPicture && settings.autoPip
        options.autoSelectEmbedSubtitle = settings.autoSelectSubtitle
        options.maxBufferDuration = Double(settings.maxBuffer)
        options.preferredForwardBufferDuration = Double(media.isLive ? settings.liveBuffer : settings.vodBuffer)
        if !media.isLive, media.startTime > 1 {
            options.startPlayTime = media.startTime
        }
        #if os(macOS)
            options.automaticWindowResize = false
        #endif
        return options
    }
}

@available(iOS 16.0, macOS 13.0, tvOS 16.0, *)
extension KSPlayerEngineView {
    func makeOptions() -> KSOptions {
        KSPlayerOptionsFactory.make(for: media)
    }
}
