//
//  SubtitleSearchView.swift
//  Lume
//
//  In-player OpenSubtitles browser: searches for subtitle tracks matching the
//  title on screen, downloads the one the viewer picks, and hands the local file
//  back for the active engine to side-load.
//
//  Presented from the engine views rather than from the controls overlay, since
//  the overlay is torn down when the controls auto-hide — a sheet anchored there
//  would vanish with it. See `subtitleSearch(isPresented:media:onPick:)`.
//

import SwiftData
import SwiftUI

struct SubtitleSearchView: View {
    let media: PlayableMedia
    /// Handed the downloaded file; the caller loads it into its engine and the
    /// sheet dismisses itself.
    var onPick: (ExternalSubtitle) -> Void

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var service = OpenSubtitlesService.shared
    @State private var query: OpenSubtitlesQuery?
    @State private var results: [OnlineSubtitle] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    /// The result currently being downloaded, so its row can show progress and
    /// a second tap can't spend two downloads from the daily quota.
    @State private var downloadingID: String?

    var body: some View {
        NavigationStack {
            List {
                if !service.isSignedIn {
                    OpenSubtitlesSignInSection()
                }
                languageSection
                resultsSection
            }
            .platformNavigationTitle("Subtitles")
            #if !os(tvOS)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            #endif
        }
        .task(id: media.id) { await runSearch() }
        // Re-run when the viewer changes languages; the API filters server-side,
        // so a new selection is a new search rather than a local filter.
        .onChange(of: service.preferredLanguages) { _, _ in
            Task { await runSearch() }
        }
    }

    // MARK: - Language

    private var languageSection: some View {
        Section {
            NavigationLink {
                SubtitleLanguagePicker()
            } label: {
                HStack {
                    Label("Languages", systemImage: "globe")
                    Spacer()
                    Text(languageSummary)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    private var languageSummary: String {
        let names = service.preferredLanguages.map { code in
            Locale.current.localizedString(forIdentifier: code)
                ?? Locale.current.localizedString(forLanguageCode: code)
                ?? code.uppercased()
        }
        return names.isEmpty ? String(localized: "Any") : names.joined(separator: ", ")
    }

    // MARK: - Results

    private var resultsSection: some View {
        Section {
            if isSearching {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching…")
                        .foregroundStyle(.secondary)
                }
            } else if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            } else if query == nil {
                Text("Subtitle search is only available for movies and episodes.")
                    .foregroundStyle(.secondary)
            } else if results.isEmpty {
                Text("No subtitles found for this title.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { subtitle in
                    Button {
                        pick(subtitle)
                    } label: {
                        SubtitleResultRow(
                            subtitle: subtitle,
                            isDownloading: downloadingID == subtitle.id
                        )
                    }
                    // Without this the whole row inherits the tint and every
                    // line renders blue, including the release name and count.
                    #if !os(tvOS)
                    .buttonStyle(.plain)
                    #endif
                    .disabled(downloadingID != nil)
                }
            }
        } header: {
            Text(media.title)
        } footer: {
            if let remaining = service.remainingDownloads {
                Text("\(remaining) downloads left today.")
            }
        }
    }

    // MARK: - Actions

    private func runSearch() async {
        errorMessage = nil
        results = []
        // Resolving the ids touches SwiftData on the main actor; the fetch that
        // follows is off it.
        guard let resolved = SubtitleSearchQuery.resolve(for: media.contentRef, in: modelContext) else {
            query = nil
            return
        }
        query = resolved
        isSearching = true
        defer { isSearching = false }
        do {
            results = try await service.search(resolved)
        } catch let error as OpenSubtitlesError {
            errorMessage = String(localized: error.message)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func pick(_ subtitle: OnlineSubtitle) {
        guard downloadingID == nil else { return }
        downloadingID = subtitle.id
        Task {
            defer { downloadingID = nil }
            do {
                let fileURL = try await service.download(subtitle)
                onPick(ExternalSubtitle(
                    id: subtitle.id,
                    label: "\(subtitle.languageName) · OpenSubtitles",
                    fileURL: fileURL
                ))
                dismiss()
            } catch let error as OpenSubtitlesError {
                errorMessage = String(localized: error.message)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Result row

private struct SubtitleResultRow: View {
    let subtitle: OnlineSubtitle
    let isDownloading: Bool

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(subtitle.languageName)
                        .font(.headline)
                    if subtitle.isHearingImpaired {
                        badge("captions.bubble")
                    }
                    if subtitle.isFromTrusted {
                        badge("checkmark.seal")
                    }
                    if subtitle.isMachineTranslated {
                        badge("wand.and.stars")
                    }
                }
                if !subtitle.releaseName.isEmpty {
                    Text(subtitle.releaseName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("\(subtitle.downloadCount) downloads")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            if isDownloading {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
    }

    private func badge(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Language picker

/// Multi-select over the languages OpenSubtitles indexes. Writes straight
/// through to `OpenSubtitlesService.preferredLanguages`, which persists the
/// choice and re-runs the search.
struct SubtitleLanguagePicker: View {
    @State private var service = OpenSubtitlesService.shared
    @State private var languages: [OpenSubtitlesLanguage] = []
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(filtered) { language in
                Button {
                    toggle(language.code)
                } label: {
                    HStack {
                        Text(language.name)
                        Spacer()
                        if service.preferredLanguages.contains(language.code) {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                }
                #if !os(tvOS)
                .buttonStyle(.plain)
                #endif
            }
        }
        .platformNavigationTitle("Languages")
        #if !os(tvOS)
            .searchable(text: $searchText, prompt: Text("Search languages"))
        #endif
            .task {
                languages = await service.languages()
            }
    }

    private var filtered: [OpenSubtitlesLanguage] {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return languages }
        return languages.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    /// Keeps at least one language selected — an empty list would ask the API
    /// for every language there is.
    private func toggle(_ code: String) {
        var selection = service.preferredLanguages
        if let index = selection.firstIndex(of: code) {
            guard selection.count > 1 else { return }
            selection.remove(at: index)
        } else {
            selection.append(code)
        }
        service.preferredLanguages = selection
    }
}

// MARK: - Presentation

extension View {
    /// Presents the OpenSubtitles browser for `media`. Applied by the engine
    /// views (not their controls overlays) so the sheet outlives the controls
    /// auto-hiding underneath it.
    func subtitleSearch(
        isPresented: Binding<Bool>,
        media: PlayableMedia,
        onPick: @escaping (ExternalSubtitle) -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            SubtitleSearchView(media: media, onPick: onPick)
                // The player forces dark; a sheet raised from it inherits the
                // app appearance otherwise and flashes light over the video.
                .preferredColorScheme(.dark)
        }
    }
}
