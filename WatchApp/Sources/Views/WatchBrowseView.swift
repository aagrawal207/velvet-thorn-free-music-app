import SwiftUI

@MainActor
struct WatchBrowseView: View {
    @Environment(WatchCompanionModel.self) private var model
    @State private var presentationID = UUID()
    @State private var isVisible = false
    let location: String
    let showNowPlaying: @MainActor () -> Void

    var body: some View {
        List {
            if !model.connection.canMessage { WatchConnectionView() }
            if let notice = model.notice { WatchNoticeView(message: notice) }
            if let error = model.libraryError { WatchLibraryFailureView(message: error) }
            if let error = model.pageErrors[location] {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                reloadButton
            }
            if let page = model.pages[location] {
                if page.items.isEmpty, model.libraryError == nil || location == "queue" {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Nothing here yet").font(.headline)
                        Text(emptyMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("watch.browse.empty")
                }
                ForEach(page.items) { item in
                    if let destination = item.destination, CompanionWire.canonicalLocation(destination) != nil {
                        NavigationLink(value: destination) { row(item, isFolder: true) }
                            .accessibilityIdentifier("watch.browse.\(item.id)")
                    } else if item.destination == nil, let displayed = model.timeline.snapshot {
                        Button {
                            let selectionPresentation = presentationID
                            let action = CompanionAction.playItem(location: page.location, itemID: item.id, revision: page.revision)
                            Task {
                                let accepted = await model.command(action, displayed: displayed)
                                if accepted, isVisible, selectionPresentation == presentationID {
                                    showNowPlaying()
                                }
                            }
                        } label: {
                            row(item, isFolder: false)
                        }
                        .disabled(!model.canChooseItem || model.loadingPages.contains(location))
                        .accessibilityHint("Plays on iPhone")
                        .accessibilityIdentifier("watch.browse.\(item.id)")
                    } else {
                        row(item, isFolder: true)
                            .foregroundStyle(.secondary)
                            .accessibilityHint("Open this item on iPhone")
                    }
                }
                if page.isTruncated {
                    Text("Showing the first \(page.items.count) items. Open Breezy on iPhone for the rest.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if model.pageErrors[location] == nil { reloadButton }
            } else if model.loadingPages.contains(location) {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading from iPhone…").font(.footnote)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("watch.browse.loading")
            } else if model.connection.canMessage, model.pageErrors[location] == nil {
                reloadButton
            }
        }
        .navigationTitle(model.pages[location]?.title ?? fallbackTitle)
        .task(id: model.contentRevision) { await model.loadPage(location) }
        .refreshable { await model.loadPage(location, force: true) }
        .onAppear {
            presentationID = UUID()
            isVisible = true
        }
        .onDisappear {
            isVisible = false
            presentationID = UUID()
        }
        .accessibilityIdentifier("watch.browse.\(location)")
    }

    private func row(_ item: CompanionItem, isFolder: Bool) -> some View {
        HStack(spacing: 8) {
            if isFolder {
                Image(systemName: symbol(for: item.destination))
                    .foregroundStyle(WatchTheme.accent)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body).lineLimit(3)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var reloadButton: some View {
        Button {
            Task { await model.loadPage(location, force: true) }
        } label: {
            Label(model.loadingPages.contains(location) ? "Updating…" : "Refresh page", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .disabled(model.loadingPages.contains(location) || !model.connection.canMessage)
        .accessibilityIdentifier("watch.browse.refresh")
    }

    private var fallbackTitle: String {
        switch location {
        case "root": "Library"
        case "favorites": "Favorites"
        case "recent": "Recently played"
        case "playlists": "Playlists"
        case "queue": "Queue"
        default: "Playlist"
        }
    }

    private var emptyMessage: String {
        switch location {
        case "favorites": "Favorite songs in Breezy on iPhone to find them here."
        case "recent": "Songs you play on iPhone appear here."
        case "playlists": "Create a playlist in Breezy on iPhone."
        case "queue": "Choose a song to start a queue on iPhone."
        default: "Add songs to this playlist on iPhone."
        }
    }

    private func symbol(for location: String?) -> String {
        switch location {
        case "favorites": "heart.fill"
        case "recent": "clock"
        case "playlists": "music.note.list"
        case "queue": "list.bullet"
        default: "music.note"
        }
    }
}
