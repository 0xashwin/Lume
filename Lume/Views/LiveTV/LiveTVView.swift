//
//  LiveTVView.swift
//  Lume
//
//  Main view for browsing live TV channels — categories sidebar; channels
//  for the selected category are loaded lazily via @Query.
//

import SwiftData
import SwiftUI

/// How the Live TV detail area presents channels: a scannable list (default) or
/// the EPG timeline grid. Persisted across launches.
enum LiveTVLayoutMode: String, CaseIterable, Identifiable {
    case list
    case guide

    var id: String {
        rawValue
    }

    var label: LocalizedStringKey {
        self == .list ? "List" : "Guide"
    }

    var systemImage: String {
        self == .list ? "list.bullet" : "tablecells"
    }

    static let storageKey = "lume.liveTV.layoutMode"
}

struct LiveTVView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    #if os(macOS)
        @Environment(\.openWindow) private var openWindow
    #endif
    @Query private var playlists: [Playlist]
    @Query(filter: #Predicate<Category> { $0.typeRaw == "live" && $0.isHidden == false })
    private var categories: [Category]

    /// Drives whether the Favorites / Recently Watched virtual sections appear in
    /// the rail. Queried across all playlists, then scoped in-memory by prefix.
    @Query(filter: #Predicate<LiveStream> { $0.isFavorite && $0.isHidden == false })
    private var favoriteStreams: [LiveStream]
    @Query(filter: #Predicate<LiveStream> { $0.lastWatchedDate != nil && $0.isHidden == false })
    private var recentStreams: [LiveStream]

    @AppStorage(PlaylistSelectionStore.key) private var selectedPlaylistID: String = ""
    @State private var selectedSection: LiveTVSection?
    @State private var showingSync = false
    @State private var playingMedia: PlayableMedia?
    @State private var showingSettings = false
    #if os(tvOS)
        @Environment(DeepLinkRouter.self) private var router
    #else
        /// Non-nil while Multi-View is up; carries the channels it opened with,
        /// when it was started from a channel rather than the toolbar.
        @State private var multiViewLaunch: MultiViewLaunch?
    #endif
    @State private var showingPaywall = false
    @State private var premium = PremiumManager.shared

    @AppStorage(SortStorageKey.liveCategories) private var categorySortRaw: String = CategorySortOption.playlist.rawValue
    @AppStorage(SortStorageKey.liveContent) private var contentSortRaw: String = ContentSortOption.playlist.rawValue
    @AppStorage(LiveTVLayoutMode.storageKey) private var layoutModeRaw: String = LiveTVLayoutMode.list.rawValue

    private var categorySort: CategorySortOption {
        CategorySortOption(rawValue: categorySortRaw) ?? .playlist
    }

    private var contentSort: ContentSortOption {
        ContentSortOption(rawValue: contentSortRaw) ?? .playlist
    }

    private var layoutMode: LiveTVLayoutMode {
        LiveTVLayoutMode(rawValue: layoutModeRaw) ?? .list
    }

    /// Guide/List segmented switch shared across platforms.
    private var layoutModePicker: some View {
        Picker("Layout", selection: $layoutModeRaw) {
            ForEach(LiveTVLayoutMode.allCases) { mode in
                Label(mode.label, systemImage: mode.systemImage).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    /// The channel detail area for the selected section, honouring the current
    /// layout mode. Shared by every platform's layout.
    private func detail(for section: LiveTVSection) -> some View {
        Group {
            if layoutMode == .guide {
                EPGGuideView(
                    scope: section.scope,
                    playlistPrefix: playlistPrefix,
                    sort: contentSort,
                    onPlay: { playChannel($0, scope: section.scope) },
                    onPlayCatchup: { playCatchup($0, cell: $1) },
                    onStartMultiView: { startMultiView(with: $0) }
                )
            } else {
                channelList(for: section)
            }
        }
        .id("\(section.id)-\(contentSort.rawValue)-\(layoutModeRaw)")
    }

    @ViewBuilder
    private func channelList(for section: LiveTVSection) -> some View {
        #if os(tvOS)
            TVChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                sort: contentSort,
                onStartMultiView: { startMultiView(with: $0) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
            .frame(maxWidth: .infinity)
        #else
            ChannelsList(
                scope: section.scope,
                playlistPrefix: playlistPrefix,
                sort: contentSort,
                onStartMultiView: { startMultiView(with: $0) },
                onPlay: { playChannel($0, scope: section.scope) }
            )
        #endif
    }

    var body: some View {
        NavigationStack {
            Group {
                if playlists.isEmpty {
                    ContentUnavailableView(
                        "No Playlists",
                        systemImage: "antenna.radiowaves.left.and.right",
                        description: Text("Add a playlist in Settings to start watching live TV")
                    )
                } else if categories.isEmpty {
                    VStack(spacing: 20) {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("Sync your playlist to load live TV channels")
                        )
                    }
                } else {
                    // Resolve the rail's sections (and the displayed one) once
                    // per render — both `displayedSection` and the layouts read
                    // them, and each resolve filters + sorts the categories.
                    let sections = sortedSections
                    let displayed = displayedSection(in: sections)
                    #if os(iOS)
                        iOSLayout(sections: sections, displayed: displayed)
                    #elseif os(tvOS)
                        tvOSLayout(sections: sections, displayed: displayed)
                    #else
                        macOSLayout(sections: sections, displayed: displayed)
                    #endif
                }
            }
            .platformNavigationTitle("Live TV")
            #if os(iOS)
                // Inline title: the category selector sits directly below the
                // nav bar, so a large title would rubber-band down and float
                // behind the selector when the channel list is overscrolled.
                .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(iOS) || os(macOS)
            .toolbar {
                if !playlists.isEmpty, !categories.isEmpty {
                    ToolbarItem(placement: .principal) {
                        layoutModePicker
                            .frame(maxWidth: 240)
                    }
                    // Its own ToolbarItem with a titled Label, for the same
                    // reason `LibraryToolbar` splits its buttons up: an item
                    // pushed into the "..." overflow needs a menu representation.
                    ToolbarItem(placement: .automatic) {
                        Button {
                            openMultiView()
                        } label: {
                            Label("Multi-View", systemImage: "rectangle.split.2x2")
                        }
                    }
                }
            }
            #endif
            .libraryToolbar(config: LibraryToolbarConfiguration(
                playlists: playlists,
                selectedPlaylistID: $selectedPlaylistID,
                categorySortRaw: $categorySortRaw,
                contentSortRaw: $contentSortRaw,
                showingSync: $showingSync,
                showingSettings: $showingSettings,
                activePlaylist: activePlaylist
            ))
            .task {
                if selectedSection == nil, let first = sortedSections.first {
                    selectedSection = first
                }
            }
            .onChange(of: selectedPlaylistID) {
                // Switching playlists invalidates the current selection, which
                // belongs to the previous playlist. Reset to the new playlist's
                // first section so the channel list stays in sync.
                selectedSection = sortedSections.first
            }
            #if os(iOS) || os(tvOS)
            .fullScreenCover(item: $playingMedia) { media in
                FullScreenPlayerView(media: media)
            }
            #endif
            #if os(iOS)
            .fullScreenCover(item: $multiViewLaunch) { launch in
                MultiViewScreen(seed: launch.seed)
            }
            #endif
            .paywall(isPresented: $showingPaywall, highlight: .multiView)
        }
    }

    // MARK: - Platform-specific layouts

    #if os(iOS)
        private func iOSLayout(sections: [LiveTVSection], displayed: LiveTVSection?) -> some View {
            VStack(spacing: 0) {
                CategoryBar(
                    sections: sections,
                    selectedSection: $selectedSection
                )

                if let displayed {
                    detail(for: displayed)
                } else {
                    ContentUnavailableView(
                        "Select a Category",
                        systemImage: "list.bullet",
                        description: Text("Choose a category from the list")
                    )
                }
            }
        }
    #endif

    private func macOSLayout(sections: [LiveTVSection], displayed: LiveTVSection?) -> some View {
        HStack(spacing: 0) {
            CategorySidebar(
                sections: sections,
                selectedSection: $selectedSection
            )
            .frame(width: 200)

            Divider()

            if let displayed {
                detail(for: displayed)
            } else {
                ContentUnavailableView(
                    "Select a Category",
                    systemImage: "list.bullet",
                    description: Text("Choose a category from the sidebar")
                )
            }
        }
    }

    #if os(tvOS)
        /// One shape for both modes: a slim category rail on the leading edge —
        /// topped by a single List/Guide switch — beside the content area, which
        /// shows either the channel list or the programme guide. Sharing one rail
        /// and one switch keeps moving between the two views consistent.
        private func tvOSLayout(sections: [LiveTVSection], displayed: LiveTVSection?) -> some View {
            TVLiveTVScreen(
                sections: sections,
                selectedSection: $selectedSection,
                displayedSection: displayed,
                layoutModeRaw: $layoutModeRaw,
                contentSort: contentSort,
                onPlay: { playChannel($0, scope: displayed?.scope) },
                onPlayCatchup: { playCatchup($0, cell: $1) },
                onOpenMultiView: { openMultiView() },
                onStartMultiView: { startMultiView(with: $0) },
                playlistPrefix: playlistPrefix
            )
        }
    #endif

    /// The playlist whose content is currently shown, resolved from the global
    /// selection. Falls back to the first playlist until the user picks one.
    private var activePlaylist: Playlist? {
        playlists.active(for: selectedPlaylistID)
    }

    /// The id prefix every Category / LiveStream of the active playlist shares.
    private var playlistPrefix: String {
        activePlaylist.map { "\($0.id.uuidString)-" } ?? ""
    }

    /// Categories scoped to the active playlist. The `@Query` fetches every
    /// playlist's categories (SwiftData can't parameterize a `@Query` on view
    /// state), so we isolate by the playlist-prefixed category `id` here.
    private var sortedCategories: [Category] {
        guard let playlistId = activePlaylist?.id else { return [] }
        let prefix = "\(playlistId.uuidString)-"
        return categorySort.sort(categories.filter { $0.id.hasPrefix(prefix) && !restriction.hides(categoryID: $0.id) })
    }

    /// Whether the active playlist has any favorited / recently-watched channels,
    /// gating the corresponding virtual sections so empty collections never show.
    /// Channels in restricted categories are excluded while a child profile is
    /// active, so those collections never surface restricted content.
    private var hasFavorites: Bool {
        !playlistPrefix.isEmpty && favoriteStreams.contains {
            $0.id.hasPrefix(playlistPrefix) && !restriction.hides(categoryID: $0.categoryId)
        }
    }

    private var hasRecents: Bool {
        !playlistPrefix.isEmpty && recentStreams.contains {
            $0.id.hasPrefix(playlistPrefix) && !restriction.hides(categoryID: $0.categoryId)
        }
    }

    /// The rail's entries: the virtual collections (when non-empty) pinned above
    /// the synced categories.
    private var sortedSections: [LiveTVSection] {
        var sections: [LiveTVSection] = []
        if hasFavorites { sections.append(.favorites) }
        if hasRecents { sections.append(.recentlyWatched) }
        sections.append(contentsOf: sortedCategories.map(LiveTVSection.category))
        return sections
    }

    /// The section to render in the detail pane. Normally the user's selection,
    /// but if that section just disappeared (a category hidden in Content
    /// Management, or the last favorite removed) fall back to the first available
    /// one rather than keep showing stale content.
    private func displayedSection(in sections: [LiveTVSection]) -> LiveTVSection? {
        guard let selectedSection else { return sections.first }
        return sections.contains { $0.id == selectedSection.id }
            ? selectedSection
            : sections.first
    }

    /// `scope` is the section the channel was picked from; it travels with the
    /// media so in-player channel surfing stays inside that list.
    private func playChannel(_ stream: LiveStream, scope: LiveChannelScope?) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist, scope: scope) else { return }
        present(media)
    }

    /// Replays a past programme from the channel's catch-up archive.
    private func playCatchup(_ stream: LiveStream, cell: EPGProgramCell) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.catchup(
                  stream: stream,
                  playlist: playlist,
                  programTitle: cell.title,
                  start: cell.start,
                  end: cell.end
              ) else { return }
        present(media)
    }

    /// Opens Multi-View on a channel picked from the list, so the grid starts
    /// with something playing rather than two empty tiles.
    private func startMultiView(with stream: LiveStream) {
        guard let playlist = activePlaylist,
              let media = PlayableMedia.from(stream: stream, playlist: playlist)
        else {
            return
        }
        openMultiView(seed: [media])
    }

    /// Opens Multi-View, or the paywall when the viewer isn't on Lume Pro.
    private func openMultiView(seed: [PlayableMedia] = []) {
        guard premium.isPremium else {
            showingPaywall = true
            return
        }
        #if os(macOS)
            // The window is a singleton, so it cannot be built around a launch:
            // hand the channels over and let the grid adopt them on appear.
            MultiViewLaunchQueue.shared.pending = seed
            openWindow(id: "multiview")
        #elseif os(tvOS)
            // Presented by `MainTabView`, above the tab bar — see the router.
            router.multiViewLaunch = MultiViewLaunch(seed: seed)
        #else
            multiViewLaunch = MultiViewLaunch(seed: seed)
        #endif
    }

    private func present(_ media: PlayableMedia) {
        if ExternalPlayback.open(media) { return }
        #if os(macOS)
            openWindow(id: "player", value: media)
        #else
            playingMedia = media
        #endif
    }
}

// MARK: - Channels List

struct ChannelsList: View {
    let scope: LiveChannelScope
    let playlistPrefix: String
    /// Seeds Multi-View with this channel, gated on Lume Pro by the host.
    let onStartMultiView: (LiveStream) -> Void
    let onPlay: (LiveStream) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(\.contentRestriction) private var restriction
    @Query private var streams: [LiveStream]
    /// Now/next EPG for the visible channels, resolved in one off-main fetch
    /// (see `ChannelEPGSnapshot`) instead of a per-card `@Query`.
    @State private var epgByChannel: [String: ChannelEPG] = [:]
    /// Observed so the EPG lookup refreshes when a guide import finishes.
    @State private var epgSync = EPGSyncService.shared
    /// How many channels are currently rendered. Grows by a page as the list
    /// nears its end so a large category loads lazily instead of all at once.
    @State private var visibleCount = LiveChannelQuery.pageSize
    /// Drives the "Clear Recently Watched" confirmation alert.
    @State private var confirmingClear = false

    init(
        scope: LiveChannelScope,
        playlistPrefix: String,
        sort: ContentSortOption,
        onStartMultiView: @escaping (LiveStream) -> Void,
        onPlay: @escaping (LiveStream) -> Void
    ) {
        self.scope = scope
        self.playlistPrefix = playlistPrefix
        self.onStartMultiView = onStartMultiView
        self.onPlay = onPlay
        _streams = Query(LiveChannelQuery.descriptor(for: scope, sort: sort))
    }

    private var scopedStreams: [LiveStream] {
        LiveChannelQuery.scoped(streams, scope: scope, playlistPrefix: playlistPrefix)
            .excludingRestricted(restriction)
    }

    /// Clears a channel's watch timestamp so it drops out of the Recently
    /// Watched list. The @Query-backed list updates once the change is saved.
    private func removeFromRecentlyWatched(_ stream: LiveStream) {
        stream.lastWatchedDate = nil
        try? modelContext.save()
    }

    /// Empties the whole Recently Watched list for the active playlist. The
    /// section drops away on its own once the last timestamp clears (its parent
    /// gates it on `hasRecents`).
    private func clearRecentlyWatched() {
        let container = modelContext.container
        Task { await StorageManager.clearRecentlyWatchedChannels(playlistPrefix: playlistPrefix, container: container) }
    }

    /// A trailing "Clear" button shown above the Recently Watched list. Stays
    /// out of the scroll view so it's always reachable no matter how far the
    /// list is scrolled.
    private var clearHeader: some View {
        HStack {
            Spacer()
            Button(role: .destructive) {
                confirmingClear = true
            } label: {
                Label("Clear", systemImage: "trash")
                    .font(.subheadline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    var body: some View {
        let channels = scopedStreams
        let visible = Array(channels.prefix(visibleCount))
        VStack(spacing: 0) {
            if scope == .recentlyWatched, !channels.isEmpty {
                clearHeader
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if channels.isEmpty {
                        ContentUnavailableView(
                            "No Channels",
                            systemImage: "antenna.radiowaves.left.and.right",
                            description: Text("This category has no channels")
                        )
                    } else {
                        ForEach(visible) { stream in
                            Button {
                                onPlay(stream)
                            } label: {
                                LiveStreamCardView(stream: stream, epg: epgByChannel[stream.epgChannelId ?? ""])
                                    .padding(.horizontal)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .liveChannelMenu(
                                isFavorite: stream.isFavorite,
                                onToggleFavorite: { LiveChannelFavorites.toggle(stream, in: modelContext) },
                                onStartMultiView: { onStartMultiView(stream) },
                                onRemoveFromRecents: scope == .recentlyWatched ? { removeFromRecentlyWatched(stream) } : nil
                            )
                            .onAppear {
                                if stream.id == visible.last?.id, visibleCount < channels.count {
                                    visibleCount = min(visibleCount + LiveChannelQuery.pageSize, channels.count)
                                }
                            }

                            Divider()
                                .padding(.leading, 88)
                        }
                    }
                }
            }
            // Reload when the visible window or channel set changes, or a guide
            // import settles — EPG is resolved only for the channels on screen.
            .task(id: "\(channels.count)-\(visible.count)-\(epgSync.isSyncing)") {
                await loadEPG(for: visible)
            }
        }
        .alert("Clear Recently Watched", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { clearRecentlyWatched() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the list of channels you've recently watched. Your favorites and the channels themselves aren't affected.")
        }
    }

    private func loadEPG(for channels: [LiveStream]) async {
        let channelIds = Array(Set(channels.compactMap(\.epgChannelId).filter { !$0.isEmpty }))
        guard !channelIds.isEmpty else {
            epgByChannel = [:]
            return
        }
        let container = modelContext.container
        let now = Date()
        epgByChannel = await Task.detached(priority: .userInitiated) {
            ChannelEPGLoader.load(container: container, channelIds: channelIds, now: now)
        }.value
    }
}

#Preview("Empty") {
    LiveTVView()
        .modelContainer(for: Playlist.self, inMemory: true)
}

#Preview("With Data") {
    LiveTVView()
        .modelContainer(previewContainer())
}

#Preview("No Playlists") {
    LiveTVView()
}
