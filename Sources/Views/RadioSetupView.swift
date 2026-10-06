import Foundation
import Observation
import SwiftUI

@MainActor
struct RadioSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var setup: RadioSetupModel
    @FocusState private var isArtistSearchFocused: Bool
    private let model: MusicAppModel

    init(experience: RadioExperience, model: MusicAppModel) {
        self.model = model
        _setup = State(initialValue: RadioSetupModel(station: experience, catalog: model.catalog))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(setup.station.title).appFont(.title2, weight: .bold)
                            Text(setup.station.description)
                                .appFont(.subheadline)
                                .foregroundStyle(AppTheme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Label("Languages follow your listening", systemImage: "character.bubble")
                            .appFont(.subheadline)
                            .foregroundStyle(AppTheme.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("radio.setup.listeningLanguages")
                        eraSection
                        artistSection
                        artistSearch
                    }
                    .padding(20)
                    .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
                // Hidden artist rows must not share a hit region with the Start control.
                .clipped()
                .contentShape(Rectangle())
                .accessibilityIdentifier("radio.setup.options")
                startControl
            }
            .background(AppTheme.background)
            .navigationTitle("Set Up Radio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        AppNavigationIntent.perform(in: model) {
                            setup.cancel()
                            dismiss()
                        }
                    } label: {
                        Text("Cancel").appFont(.body).frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("radio.setup.cancel")
                }
            }
        }
        .presentationDetents([.large])
        .appSheetChrome()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isArtistSearchFocused {
                HStack {
                    Spacer()
                    Button { isArtistSearchFocused = false } label: {
                        Label("Done", systemImage: "keyboard.chevron.compact.down")
                            .appFont(.subheadline, weight: .semibold)
                            .padding(.horizontal, 16)
                            .frame(minWidth: 44, minHeight: 48)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide keyboard")
                    .accessibilityIdentifier("radio.setup.dismissKeyboard")
                }
                .padding(.horizontal, 8)
                .background(.regularMaterial)
            }
        }
        .task(id: setup.searchRequest) {
            do {
                try await Task.sleep(for: .milliseconds(320))
                try Task.checkCancellation()
                await setup.searchArtists()
            } catch { }
        }
        .onDisappear { setup.cancel() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("radio.setup")
    }

    private var eraSection: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 8))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Era Preference").appFont(.headline, weight: .semibold)
            layout {
                ForEach(RadioEra.allCases) { era in
                    Button { setup.selectEra(era) } label: {
                        Text(era.title)
                            .appFont(.subheadline, weight: .semibold)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(setup.era == era ? AppTheme.accent.opacity(0.18) : AppTheme.raised,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(setup.era == era ? .isSelected : [])
                    .accessibilityIdentifier("radio.setup.era.\(era.rawValue)")
                }
            }
            Text(setup.era.detail).appFont(.caption).foregroundStyle(AppTheme.secondaryText)
            Text("Uses older or newer starting songs. Related radio songs can span other years.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
        }
    }

    private var artistSection: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        return VStack(alignment: .leading, spacing: 8) {
            layout {
                Text("Artists (optional)").appFont(.headline, weight: .semibold)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(setup.selectedArtists.count) of 4 hints")
                    .appFont(.caption)
                    .foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("radio.setup.selectionCount")
            }
            Text("The station sets the mood. Artist hints nudge the mix; other artists can play too.")
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
            Button("Clear Artist Hints") { setup.clearArtistHints() }
                .appFont(.subheadline)
                .frame(minHeight: 44)
                .disabled(setup.selectedArtists.isEmpty)
                .accessibilityIdentifier("radio.setup.clearArtists")
            if setup.artistChoices.isEmpty {
                Text("Search below to add artists you want to hear more of.")
                    .appFont(.subheadline)
                    .foregroundStyle(AppTheme.secondaryText)
            }
            ForEach(setup.artistChoices, id: \.self) { artist in
                let selected = setup.isSelected(artist)
                Button { setup.toggleArtist(artist) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? AppTheme.accent : AppTheme.secondaryText)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(artist.name).appFont(.body, weight: .medium)
                            Text(setup.status(for: artist))
                                .appFont(.caption)
                                .foregroundStyle(AppTheme.secondaryText)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(12)
                    .frame(minHeight: 64)
                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(artist.name)
                .accessibilityValue(selected ? "Selected. \(setup.status(for: artist))" : "Not selected")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("radio.setup.artist.\(RadioConfiguration.artistKey(artist))")
            }
            if let notice = setup.notice {
                Text(notice).appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                    .accessibilityIdentifier("radio.setup.notice")
            }
        }
    }

    private var artistSearch: some View {
        @Bindable var setup = setup
        return VStack(alignment: .leading, spacing: 10) {
            Text("Add an Artist").appFont(.headline, weight: .semibold)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.secondaryText)
                TextField("Search artists", text: $setup.artistQuery)
                    .appFont(.body)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isArtistSearchFocused)
                    .submitLabel(.search)
                    .onSubmit { isArtistSearchFocused = false }
                    .accessibilityIdentifier("radio.setup.artistSearch")
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 48)
            .background(AppTheme.raised, in: RoundedRectangle(cornerRadius: 8))
            if let error = setup.artistSearchError {
                Text(error).appFont(.caption).foregroundStyle(AppTheme.secondaryText)
                Button("Try Again") { setup.retryArtistSearch() }
                    .appFont(.subheadline)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("radio.setup.retryArtistSearch")
            } else if setup.isSearchingArtists {
                Text("Searching artists…").appFont(.caption).foregroundStyle(AppTheme.secondaryText)
            } else if setup.hasSearchedArtists && setup.artistResults.isEmpty {
                Text("No artists found. Try another name.").appFont(.caption).foregroundStyle(AppTheme.secondaryText)
            }
            ForEach(setup.artistResults) { artist in
                Button {
                    setup.addArtist(artist)
                    isArtistSearchFocused = false
                } label: {
                    HStack(spacing: 12) {
                        ArtworkView(url: artist.artworkURL, title: artist.title, size: 44, cornerRadius: 22)
                        Text(artist.title).appFont(.body).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "plus.circle").foregroundStyle(AppTheme.accent)
                    }
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(artist.title)")
                .accessibilityIdentifier("radio.setup.addArtist.\(artist.id)")
            }
        }
    }

    private var startControl: some View {
        VStack(spacing: 8) {
            Text(setup.startHelp)
                .appFont(.caption)
                .foregroundStyle(AppTheme.secondaryText)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .accessibilityIdentifier("radio.setup.summary")
            Button {
                guard let experience = setup.submit() else { return }
                model.startRadio(experience)
                dismiss()
            } label: {
                HStack {
                    Spacer()
                    Text("Start Radio").appFont(.body, weight: .semibold)
                    Spacer()
                    Image(systemName: "play.fill").frame(width: 24, height: 24)
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .background(AppTheme.accent.opacity(setup.canStart ? 0.22 : 0.1), in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!setup.canStart)
            .accessibilityValue(setup.selectedArtists.isEmpty ? "Style defaults"
                                : "\(setup.selectedArtists.count) artist \(setup.selectedArtists.count == 1 ? "hint" : "hints")")
            .accessibilityIdentifier("radio.setup.start")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: AppLayout.contentMaxWidth(for: horizontalSizeClass))
        .frame(maxWidth: .infinity)
        .background(AppTheme.background)
    }
}

@MainActor @Observable
final class RadioSetupModel {
    let station: RadioExperience
    private(set) var era: RadioEra
    private(set) var languages: Set<MusicLanguage>
    private(set) var notice: String?
    var artistQuery = "" {
        didSet {
            if artistQuery.trimmingCharacters(in: .whitespacesAndNewlines) != oldValue.trimmingCharacters(in: .whitespacesAndNewlines) {
                searchGeneration = UUID()
                artistResults = []
                artistSearchError = nil
                hasSearchedArtists = false
                isSearchingArtists = false
            }
        }
    }
    private(set) var artistResults: [MusicCollection] = []
    private(set) var artistSearchError: String?
    private(set) var isSearchingArtists = false
    private(set) var hasSearchedArtists = false
    private var selectedKeys: Set<String>
    private var addedArtists: [MusicCollection] = []
    private var searchAttempt = 0
    private var closed = false
    private var submitted = false
    @ObservationIgnored private let configurationID = UUID()
    @ObservationIgnored private let catalog: any MusicCatalogProviding
    @ObservationIgnored private var searchGeneration = UUID()

    init(station: RadioExperience, languages: Set<MusicLanguage> = Set(MusicLanguage.allCases), catalog: any MusicCatalogProviding) {
        let configuration = RadioConfiguration(station: station, languages: languages)
        self.station = station
        self.era = configuration.era
        self.languages = configuration.languages
        self.selectedKeys = Set(configuration.artists.map(RadioConfiguration.artistKey))
        self.catalog = catalog
    }

    var artistChoices: [ArtistCredit] {
        var seen = Set<String>()
        return (RadioConfiguration.defaultArtists(station: station, languages: languages)
                + addedArtists.map { ArtistCredit(name: $0.title, id: $0.id) })
            .filter { seen.insert(RadioConfiguration.artistKey($0)).inserted }
    }

    var selectedArtists: [ArtistCredit] { artistChoices.filter(isSelected) }

    var configuration: RadioConfiguration {
        var value = RadioConfiguration(station: station, languages: languages, id: configurationID)
        value.languages = languages
        value.era = era
        value.artists = selectedArtists
        return value
    }

    var canStart: Bool {
        !closed && !submitted && configuration.validationMessage == nil
    }

    var startHelp: String {
        if let message = configuration.validationMessage { return message }
        return selectedArtists.isEmpty ? "Start from the station’s mood. No artist hints needed."
            : "Start from the station’s mood, with your artist hints."
    }

    func isSelected(_ artist: ArtistCredit) -> Bool { selectedKeys.contains(RadioConfiguration.artistKey(artist)) }

    func status(for artist: ArtistCredit) -> String {
        isSelected(artist) ? "Helps steer this radio" : "Optional artist hint"
    }

    func selectEra(_ value: RadioEra) {
        guard !closed, !submitted, era != value else { return }
        era = value
    }

    func setLanguage(_ language: MusicLanguage, selected: Bool) {
        guard !closed, !submitted else { return }
        if selected { languages.insert(language) } else { languages.remove(language) }
        selectedKeys.formIntersection(artistChoices.map(RadioConfiguration.artistKey))
        notice = nil
    }

    func setArtist(_ artist: ArtistCredit, selected: Bool) {
        guard !closed, !submitted else { return }
        let key = RadioConfiguration.artistKey(artist)
        guard !selected || selectedKeys.contains(key) || selectedArtists.count < RadioConfiguration.maximumArtists else {
            notice = "You can use up to four artist hints. Uncheck one to add another."
            return
        }
        if selected { selectedKeys.insert(key) }
        else { selectedKeys.remove(key) }
        notice = nil
    }

    func toggleArtist(_ artist: ArtistCredit) {
        setArtist(artist, selected: !isSelected(artist))
    }

    func clearArtistHints() {
        guard !closed, !submitted else { return }
        selectedKeys = []
        notice = nil
    }

    func addArtist(_ collection: MusicCollection) {
        guard !closed, !submitted, collection.kind == .artist, !collection.id.isEmpty else { return }
        let credit = ArtistCredit(name: collection.title, id: collection.id)
        let key = RadioConfiguration.artistKey(credit)
        guard !key.isEmpty else { return }
        if !artistChoices.contains(where: { RadioConfiguration.artistKey($0) == key }) { addedArtists.append(collection) }
        setArtist(credit, selected: true)
        artistQuery = ""
        artistResults = []
        searchGeneration = UUID()
    }

    func submit() -> RadioExperience? {
        guard canStart else { return nil }
        submitted = true
        return configuration.experience()
    }

    func cancel() {
        closed = true
        searchGeneration = UUID()
        isSearchingArtists = false
    }

    struct SearchRequest: Hashable {
        let query: String
        let attempt: Int
    }

    var searchRequest: SearchRequest {
        SearchRequest(query: artistQuery.trimmingCharacters(in: .whitespacesAndNewlines), attempt: searchAttempt)
    }

    func retryArtistSearch() { searchAttempt += 1 }

    func searchArtists() async {
        let query = searchRequest.query
        let token = UUID()
        searchGeneration = token
        artistResults = []
        artistSearchError = nil
        hasSearchedArtists = false
        guard !closed, !submitted, !query.isEmpty else { isSearchingArtists = false; return }
        isSearchingArtists = true
        defer { if searchGeneration == token { isSearchingArtists = false } }
        do {
            let page = try await catalog.search(query: query, filter: .artists, continuation: nil)
            try Task.checkCancellation()
            guard !closed, !submitted, searchGeneration == token, query == searchRequest.query else { return }
            var ids = Set<String>()
            artistResults = Array(page.collections.filter {
                $0.kind == .artist && !$0.id.isEmpty && !SearchRelevance.normalize($0.title).isEmpty && ids.insert($0.id).inserted
            }.prefix(8))
            hasSearchedArtists = true
        } catch {
            guard !closed, !submitted, searchGeneration == token, query == searchRequest.query, !Task.isCancelled else { return }
            artistSearchError = error.localizedDescription
            hasSearchedArtists = true
        }
    }
}
