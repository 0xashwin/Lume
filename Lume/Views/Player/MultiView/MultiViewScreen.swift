//
//  MultiViewScreen.swift
//  Lume
//
//  Multi-View: two to four live streams playing at once, one of them carrying
//  the audio. Useful for sports, and the only way to watch two channels from
//  providers that allow a single concurrent connection per playlist — hence the
//  picker being free to reach across playlists (#43).
//
//  Deliberately not `FullScreenPlayerView` repeated N times: that host owns
//  watch-progress writing, Next Up, skip-intro, AirPlay routing and the audio
//  session, all of which are single-stream concerns. A tile is video plus mute
//  (see `MultiViewTilePlayer`).
//

import AVFoundation
import SwiftUI

/// `UUID` is not `Identifiable`, so the sheet needs this to carry which tile the
/// channel picker is changing.
private struct MultiViewPickerTarget: Identifiable {
    let id: MultiViewSlot.ID
}

/// Presents the tile channel picker. A sheet on iOS/macOS; on tvOS its own
/// `fullScreenCover` stacked over Multi-View's, because a tvOS cover always
/// dismisses itself on Menu and nothing can stop it (neither `onExitCommand` nor
/// `interactiveDismissDisabled`). Nesting turns that into the behaviour we want:
/// Menu in the picker closes only the picker, Menu in the grid closes Multi-View.
/// Presenting it also takes focus off the grid, which tvOS would otherwise keep
/// reachable behind a plain overlay.
///
/// A `ViewModifier` rather than an inline `#if`: a conditional in the middle of a
/// modifier chain is something SwiftFormat cannot indent readably.
private struct MultiViewPickerPresentation: ViewModifier {
    @Binding var target: MultiViewPickerTarget?
    let usedMediaIDs: Set<String>
    let playlistsInUse: (MultiViewSlot.ID) -> Set<UUID>
    let onPick: (PlayableMedia, MultiViewSlot.ID) -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
            content.fullScreenCover(item: $target) { target in
                MultiViewChannelPickerTV(
                    usedMediaIDs: usedMediaIDs,
                    playlistsInUse: playlistsInUse(target.id),
                    onPick: { onPick($0, target.id) }
                )
            }
        #else
            content.sheet(item: $target) { target in
                MultiViewChannelPicker(
                    usedMediaIDs: usedMediaIDs,
                    playlistsInUse: playlistsInUse(target.id),
                    onPick: { onPick($0, target.id) }
                )
            }
        #endif
    }
}

struct MultiViewScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
        @Environment(\.dismissWindow) private var dismissWindow
    #endif

    @State private var session: MultiViewSession
    /// The tile whose channel picker is open.
    @State private var pickingSlot: MultiViewPickerTarget?
    #if os(tvOS)
        /// Drives the close button's own focus colours — never a size or a
        /// position, so the focus engine has no layout to fight with.
        @FocusState private var isCloseFocused: Bool
        /// Same, for the layout pills.
        @FocusState private var focusedLayout: MultiViewLayout?
    #endif

    /// - Parameter seed: channels to start with. Empty tiles prompt for a channel,
    ///   so opening Multi-View cold is a valid entry.
    init(seed: [PlayableMedia] = []) {
        let stored = UserDefaults.standard.integer(forKey: MultiViewLayout.storageKey)
        let fitting = MultiViewLayout.fitting(seed.count)
        let layout = MultiViewLayout(rawValue: max(stored, fitting.rawValue)) ?? fitting
        _session = State(initialValue: MultiViewSession(seed: seed, layout: layout))
    }

    private var tileSpacing: CGFloat {
        #if os(tvOS)
            16
        #else
            6
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            grid
        }
        .background(Color.black.ignoresSafeArea())
        #if os(iOS)
            .statusBarHidden(true)
        #endif
            .persistentSystemOverlays(.hidden)
            .preferredColorScheme(.dark)
            .task {
                // The tiles' QoE reports would be nonsense against a summary that
                // models one stream at a time.
                PlaybackQoE.shared.isSuspended = true
                // Background indexing merges periodic saves into the main context,
                // which hitches every running decoder — more so with four of them.
                ContentIndexingService.shared.isPlaybackActive = true
                configureAudioSession()
            }
            .onChange(of: session.layout) { _, layout in
                UserDefaults.standard.set(layout.rawValue, forKey: MultiViewLayout.storageKey)
            }
            .modifier(MultiViewPickerPresentation(
                target: $pickingSlot,
                usedMediaIDs: session.usedMediaIDs,
                playlistsInUse: { session.playlistsInUse(excluding: $0) },
                onPick: { media, slotID in
                    session.setMedia(media, in: slotID)
                    pickingSlot = nil
                }
            ))
        #if os(iOS) || os(tvOS)
            .onChange(of: scenePhase) { _, phase in
                // No engine plays Multi-View in the background, and four streams left
                // buffering behind the Home screen hold four decoders. `.inactive` is
                // a transient system overlay, so only a real move out acts.
                if phase == .background {
                    close()
                }
            }
        #endif
            .onDisappear {
                releaseAudioSession()
                ContentIndexingService.shared.isPlaybackActive = false
                PlaybackQoE.shared.isSuspended = false
            }
        #if os(tvOS)
            // Only reached when the picker isn't presented — its own cover handles
            // Menu while it is up.
            .onExitCommand { close() }
        #endif
    }

    // MARK: - Grid

    private var grid: some View {
        // The arrangement depends on the container's aspect, not its size class:
        // an iPad in portrait and in landscape are both `.regular`, yet only one
        // of them can show two tiles side by side and keep them watchable.
        GeometryReader { proxy in
            let rows = session.layout.rows(isPortrait: proxy.size.height > proxy.size.width)
            VStack(spacing: tileSpacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: tileSpacing) {
                        ForEach(row, id: \.self) { index in
                            if session.slots.indices.contains(index) {
                                tile(at: index)
                            }
                        }
                    }
                }
            }
        }
        .padding(tileSpacing)
        #if os(tvOS)
            .focusSection()
        #endif
    }

    private func tile(at index: Int) -> some View {
        let slot = session.slots[index]
        return MultiViewTile(
            slot: slot,
            hasAudio: session.isAudioSlot(slot.id),
            onFocusAudio: { session.focusAudio(on: slot.id) },
            onPickChannel: { pickingSlot = MultiViewPickerTarget(id: slot.id) },
            onRemove: { session.setMedia(nil, in: slot.id) }
        )
        // Identity follows the slot, not its position, so filling or clearing one
        // tile never tears down a sibling's player.
        .id(slot.id)
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack(spacing: 12) {
            closeButton
            Spacer(minLength: 12)
            layoutPicker
        }
        .padding(.horizontal, barHorizontalPadding)
        .padding(.vertical, barVerticalPadding)
        #if os(tvOS)
            .focusSection()
        #endif
    }

    private var barHorizontalPadding: CGFloat {
        #if os(tvOS)
            48
        #else
            12
        #endif
    }

    private var barVerticalPadding: CGFloat {
        #if os(tvOS)
            32
        #else
            8
        #endif
    }

    private var closeButton: some View {
        Button {
            close()
        } label: {
            Label("Close", systemImage: "xmark")
                .labelStyle(.iconOnly)
                .font(.system(size: closeGlyphSize, weight: .semibold))
                .foregroundStyle(closeForeground)
                .frame(width: closeDiameter, height: closeDiameter)
                .background(closeFill, in: Circle())
        }
        .accessibilityLabel("Close Multi-View")
        #if os(tvOS)
            // Not `.plain`: on tvOS that leaves the system to paint its own white
            // focus fill *behind* the glyph, which is also white — an invisible
            // button exactly when it has focus. Own the focus colours instead.
            .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
            .focused($isCloseFocused)
        #else
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
        #endif
    }

    private var closeGlyphSize: CGFloat {
        #if os(tvOS)
            22
        #else
            15
        #endif
    }

    private var closeDiameter: CGFloat {
        #if os(tvOS)
            52
        #else
            36
        #endif
    }

    private var closeForeground: Color {
        #if os(tvOS)
            isCloseFocused ? .black : .white
        #else
            .white
        #endif
    }

    private var closeFill: Color {
        #if os(tvOS)
            isCloseFocused ? .white : .white.opacity(0.12)
        #else
            .white.opacity(0.12)
        #endif
    }

    @ViewBuilder
    private var layoutPicker: some View {
        #if os(tvOS)
            HStack(spacing: 10) {
                ForEach(MultiViewLayout.allCases) { layout in
                    Button {
                        session.layout = layout
                    } label: {
                        let isActive = session.layout == layout
                        let isItemFocused = focusedLayout == layout
                        Image(systemName: layout.systemImage)
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 72, height: 52)
                            .foregroundStyle(isItemFocused || isActive ? .black : .white)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(pillFill(isFocused: isItemFocused, isActive: isActive))
                            )
                    }
                    .buttonStyle(TVCardButtonStyle(focusScale: 1.06))
                    .focused($focusedLayout, equals: layout)
                    .accessibilityLabel(Text(layout.title))
                }
            }
        #else
            Picker("Layout", selection: Binding(
                get: { session.layout },
                set: { session.layout = $0 }
            )) {
                ForEach(MultiViewLayout.allCases) { layout in
                    Image(systemName: layout.systemImage)
                        .accessibilityLabel(Text(layout.title))
                        .tag(layout)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 180)
        #endif
    }

    #if os(tvOS)
        /// Focus wins over the active state: a focused pill is fully white, the
        /// active-but-unfocused one keeps a dimmer white so the current layout
        /// still reads.
        private func pillFill(isFocused: Bool, isActive: Bool) -> AnyShapeStyle {
            if isFocused { return AnyShapeStyle(.white) }
            if isActive { return AnyShapeStyle(.white.opacity(0.6)) }
            return AnyShapeStyle(.white.opacity(0.12))
        }
    #endif

    // MARK: - Lifecycle

    private func close() {
        #if os(macOS)
            dismissWindow(id: "multiview")
        #else
            dismiss()
        #endif
    }

    /// Plain `.playback` / `.moviePlayback`, without the full-screen player's
    /// request for the route's full channel width: only one tile is audible, and
    /// asking for an HDMI surround layout for a muted 2×2 grid would negotiate a
    /// wider route than anything here can fill.
    private func configureAudioSession() {
        #if os(iOS) || os(tvOS)
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true, options: [])
        #endif
    }

    private func releaseAudioSession() {
        #if os(iOS) || os(tvOS)
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
