import SwiftUI

@MainActor
struct LiveRadioView: View {
    let browser: LiveRadioBrowser
    let player: PlayerController
    let isOffline: Bool
    let onSelect: @MainActor (LiveRadioStation) -> Void
    @State private var filter = LiveRadioFilter()
    @State private var favoritesOnly = false
    @State private var showsFilters = false
    @State private var attempt = 0
    private static let countries: [(code: String, title: String)] = Locale.Region.isoRegions.compactMap { region in
        let code = region.identifier
        guard code.utf8.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }),
              let title = Locale.current.localizedString(forRegionCode: code) else { return nil }
        return (code: code, title: title)
    }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

    private struct Request: Equatable {
        let filter: LiveRadioFilter
        let offline: Bool
        let favoritesOnly: Bool
        let attempt: Int
    }

    var body: some View {
        List {
            Section {
                TextField("Station Name", text: $filter.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .accessibilityIdentifier("liveRadio.search")
                Toggle("Favorites", isOn: $favoritesOnly)
                    .accessibilityIdentifier("liveRadio.favorites")
                DisclosureGroup("Filters", isExpanded: $showsFilters) {
                    Picker("Country", selection: $filter.countryCode) {
                        Text("All Countries").tag("")
                        ForEach(Self.countries, id: \.code) { country in
                            Text(country.title).tag(country.code)
                        }
                    }
                        .accessibilityIdentifier("liveRadio.country")
                    TextField("Language (english, hindi…)", text: $filter.language)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("liveRadio.language")
                    TextField("Tags, Separated by Commas", text: $filter.tags)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("liveRadio.tags")
                    Button("Clear Filters") { filter = LiveRadioFilter() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("liveRadio.clearFilters")
                }
                Button {
                    favoritesOnly = false
                    filter = .npr
                    attempt += 1
                } label: {
                    Label("Find NPR Stations", systemImage: "dot.radiowaves.left.and.right")
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("liveRadio.npr")
            } footer: {
                Text("NPR results use the directory’s station tags. Search a local call sign by name if it isn’t listed. All tags must match.")
            }

            if let message = browser.favorites.errorMessage {
                Section {
                    Text(message)
                    Button("Reload Station Favorites") { browser.favorites.reload() }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("liveRadio.favorites.reload")
                }
            }

            Section {
                if (browser.isLoading || !browser.hasSearched) && !favoritesOnly {
                    ProgressView("Finding stations…").accessibilityIdentifier("liveRadio.loading")
                } else if let message = browser.errorMessage, !favoritesOnly {
                    Text(message)
                    Button("Try Again") { attempt += 1 }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("liveRadio.retry")
                } else if visibleStations.isEmpty, browser.isVerifying, !favoritesOnly {
                    ProgressView("Checking stations…").accessibilityIdentifier("liveRadio.verifying")
                } else if visibleStations.isEmpty {
                    Text(favoritesOnly ? "No saved stations match these filters." : "No working stations found. Try fewer filters.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("liveRadio.empty")
                } else {
                    ForEach(visibleStations) { station in stationRow(station) }
                    if browser.isVerifying, !favoritesOnly {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking more stations…").foregroundStyle(.secondary)
                        }
                        .frame(minHeight: 44)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("liveRadio.verifying")
                    }
                }
            } header: {
                Text(favoritesOnly ? "Saved Stations" : "Stations")
            } footer: {
                if !favoritesOnly, browser.hiddenCount > 0 {
                    Text(browser.hiddenCount == 1 ? "1 station that didn’t respond is hidden."
                         : "\(browser.hiddenCount) stations that didn’t respond are hidden.")
                        .accessibilityIdentifier("liveRadio.hiddenCount")
                }
            }

            Section {
                Link("Directory by Radio Browser", destination: URL(string: "https://www.radio-browser.info/")!)
                    .frame(minHeight: 44)
                Text("Live stations need an internet connection. Velvet Thorn briefly checks each listed station’s stream so only working ones appear, so those broadcasters receive your network address, as they do when you listen. Favorites stay on this device and may be included in device backups.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Live Radio")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("liveRadio.screen")
        .task(id: Request(filter: filter, offline: isOffline, favoritesOnly: favoritesOnly, attempt: attempt)) {
            guard !favoritesOnly else { browser.cancelSearch(); return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                try Task.checkCancellation()
                await browser.search(filter, isOffline: isOffline)
            } catch { }
        }
        .onDisappear { browser.cancelSearch() }
    }

    private var visibleStations: [LiveRadioStation] {
        guard favoritesOnly else { return browser.stations }
        return browser.favorites.stations.filter { station in
            (filter.name.isEmpty || station.name.localizedCaseInsensitiveContains(filter.name))
                && (filter.countryCode.isEmpty || station.countryCode.caseInsensitiveCompare(filter.countryCode) == .orderedSame)
                && (filter.language.isEmpty || station.languages.contains { $0.caseInsensitiveCompare(filter.language) == .orderedSame })
                && filter.tags.split(separator: ",").allSatisfy { tag in
                    station.tags.contains { $0.caseInsensitiveCompare(tag.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
                }
        }
    }

    private func stationRow(_ station: LiveRadioStation) -> some View {
        let selected = player.liveStation?.id == station.id
        return HStack(spacing: 8) {
            Button { onSelect(station) } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "dot.radiowaves.left.and.right" : "radio")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.name).font(.headline)
                        Text(station.subtitle.isEmpty ? "Live Radio" : station.subtitle)
                            .font(.caption).foregroundStyle(.secondary)
                        if selected { Text(player.isLoading ? "Connecting…" : player.isPlaying ? "Live" : "Paused").font(.caption) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isOffline)
            .accessibilityLabel("Play \(station.name), Live Radio")
            .accessibilityIdentifier("liveRadio.station.\(station.id.uuidString.lowercased())")
            Button { browser.favorites.toggle(station) } label: {
                Image(systemName: browser.favorites.contains(station) ? "heart.fill" : "heart")
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(browser.favorites.requiresReload)
            .accessibilityLabel(browser.favorites.contains(station) ? "Remove Station Favorite" : "Save Station Favorite")
            .accessibilityIdentifier("liveRadio.favorite.\(station.id.uuidString.lowercased())")
        }
    }
}

@MainActor
struct LiveRadioMiniPlayer: View {
    let player: PlayerController
    let onOpen: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "radio")
                        .font(.title2)
                        .frame(width: 44, height: 44)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(player.displayTitle ?? "Live Radio")
                            .appFont(.subheadline, weight: .semibold)
                            .lineLimit(1)
                        Text(status)
                            .appFont(.caption)
                            .foregroundStyle(AppTheme.primaryText.opacity(0.75))
                            .lineLimit(1)
                            .accessibilityIdentifier("miniPlayer.live.status")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 52)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("Open player, \(player.displayTitle ?? "Live Radio")")
            .accessibilityValue(status)
            .accessibilityIdentifier("miniPlayer.open")
            .layoutPriority(1)
            Button {
                if player.errorMessage != nil { player.retry() } else { player.togglePlayback() }
            } label: {
                ZStack {
                    Image(systemName: player.errorMessage != nil ? "arrow.clockwise" : active ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .opacity(player.isLoading ? 0 : 1)
                    ProgressView().tint(AppTheme.primaryText)
                        .opacity(player.isLoading ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(player.errorMessage != nil ? "Retry Playback" : active ? "Pause" : "Play")
            .accessibilityIdentifier("miniPlayer.playPause")
            Button { player.stopLiveRadio() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 52, height: 52)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop Live Radio")
            .accessibilityIdentifier("miniPlayer.live.stop")
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.primaryText)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 64)
        .appGlass(in: Capsule(), interactive: true)
        .accessibilityElement(children: .contain)
        .contentShape(.accessibility, Capsule())
        .accessibilityIdentifier("miniPlayer.container")
    }

    private var active: Bool { player.isPlaying || player.isLoading }
    private var status: String {
        if player.errorMessage != nil { return "Couldn’t connect" }
        return player.isLoading ? "Connecting…" : player.isPlaying ? "Live Radio" : "Live Radio · Paused"
    }
}
