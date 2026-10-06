import CarPlay
import UIKit

@MainActor
struct CarPlayTemplateLimits {
    let tabs: Int
    let items: Int
    let sections: Int

    init(tabs: Int = CPTabBarTemplate.maximumTabCount,
         items: Int = CPListTemplate.maximumItemCount,
         sections: Int = CPListTemplate.maximumSectionCount) {
        self.tabs = max(0, min(4, tabs))
        self.items = max(0, items)
        self.sections = max(0, sections)
    }
}

@MainActor
final class CarPlayListContext {
    let connection: UUID
    let location: String
    let reload: @MainActor @Sendable (CPListTemplate) -> Void
    var renderID = UUID()
    var page: CompanionPage?
    var sessionID: UUID?
    var hasError = false
    var displayedItemLimit = 0
    var displayedSectionLimit = 0

    init(connection: UUID, location: String, reload: @escaping @MainActor @Sendable (CPListTemplate) -> Void) {
        self.connection = connection
        self.location = location
        self.reload = reload
    }
}

@MainActor
struct CarPlayListTemplates {
    let limits: CarPlayTemplateLimits

    func make(location: String, title: String, connection: UUID,
              reload: @escaping @MainActor @Sendable (CPListTemplate) -> Void) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.userInfo = CarPlayListContext(connection: connection, location: location, reload: reload)
        loading(template)
        return template
    }

    func loading(_ template: CPListTemplate) {
        retireRows(template, hasError: false)
        installReload(on: template)
        template.emptyViewTitleVariants = ["Loading your library…", "Loading…"]
        template.emptyViewSubtitleVariants = []
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = true }
        template.updateSections([])
    }

    func display(_ page: CompanionPage, sessionID: UUID, on template: CPListTemplate,
                 select: @escaping @MainActor @Sendable (CompanionItem) -> Void) {
        guard let context = template.userInfo as? CarPlayListContext else { return }
        retireRows(template, hasError: false)
        context.page = page
        context.sessionID = sessionID
        context.displayedItemLimit = limits.items
        context.displayedSectionLimit = limits.sections
        installReload(on: template)
        let renderID = context.renderID
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = false }
        let empty = emptyMessage(for: page.location)
        template.emptyViewTitleVariants = [empty.title]
        template.emptyViewSubtitleVariants = [empty.subtitle]
        guard limits.items > 0, limits.sections > 0 else {
            template.emptyViewTitleVariants = ["Browsing isn’t available"]
            template.emptyViewSubtitleVariants = ["Try Reload when CarPlay is ready."]
            template.updateSections([])
            return
        }
        let rows = page.items.prefix(limits.items).map { entry in
            let row = CPListItem(text: entry.title, detailText: entry.subtitle,
                                 image: UIImage(systemName: entry.destination == nil ? "music.note" : "music.note.list"))
            row.accessoryType = entry.destination == nil ? .none : .disclosureIndicator
            row.handler = { @Sendable [weak context] _, completion in
                defer { completion() }
                // Apple documents CPListItem handlers on the main queue; no non-Sendable completion escapes it.
                MainActor.assumeIsolated {
                    guard context?.renderID == renderID else { return }
                    select(entry)
                }
            }
            return row
        }
        let truncated = page.isTruncated || page.items.count > rows.count
        let noun = rows.count == 1 ? "item" : "items"
        let header = truncated ? "First \(rows.count) \(noun) · More on iPhone" : nil
        template.updateSections(rows.isEmpty ? [] : [CPListSection(items: rows, header: header, sectionIndexTitle: nil)])
    }

    func error(on template: CPListTemplate, title: String, message: String,
               actionTitle: String = "Retry", actionSymbol: String = "arrow.clockwise",
               action: @escaping @MainActor @Sendable () -> Void) {
        retireRows(template, hasError: true)
        guard let context = template.userInfo as? CarPlayListContext else { return }
        let renderID = context.renderID
        if #available(iOS 18.4, *) { template.showsSpinnerWhileEmpty = false }
        template.emptyViewTitleVariants = [title]
        template.emptyViewSubtitleVariants = [message]
        template.trailingNavigationBarButtons = [CPBarButton(title: actionTitle) { @Sendable [weak context] _ in
            Task { @MainActor [weak context] in
                guard context?.renderID == renderID else { return }
                action()
            }
        }]
        guard limits.items > 0, limits.sections > 0 else { template.updateSections([]); return }
        let actionRow = CPListItem(text: actionTitle, detailText: limits.items == 1 ? message : nil,
                                   image: UIImage(systemName: actionSymbol))
        actionRow.handler = { @Sendable [weak context] _, completion in
            defer { completion() }
            MainActor.assumeIsolated {
                guard context?.renderID == renderID else { return }
                action()
            }
        }
        var rows = [actionRow]
        if limits.items > 1 {
            let messageRow = CPListItem(text: title, detailText: message)
            messageRow.isEnabled = false
            rows.insert(messageRow, at: 0)
        }
        template.updateSections([CPListSection(items: rows)])
    }

    private func retireRows(_ template: CPListTemplate, hasError: Bool) {
        guard let context = template.userInfo as? CarPlayListContext else { return }
        context.renderID = UUID()
        context.page = nil
        context.sessionID = nil
        context.hasError = hasError
    }

    private func installReload(on template: CPListTemplate) {
        guard let context = template.userInfo as? CarPlayListContext else { return }
        let renderID = context.renderID
        template.trailingNavigationBarButtons = [CPBarButton(title: "Reload") { @Sendable [weak template, weak context] _ in
            Task { @MainActor [weak template, weak context] in
                guard let template, let context, context.renderID == renderID else { return }
                context.reload(template)
            }
        }]
    }

    private func emptyMessage(for location: String) -> (title: String, subtitle: String) {
        switch location {
        case "favorites": ("No favorites yet", "Favorite songs in Velvet Thorn to find them here.")
        case "recent": ("Nothing played yet", "Songs you listen to will appear here when listening history is on.")
        case "playlists": ("No playlists yet", "Create a playlist in Velvet Thorn to find it here.")
        case "queue": ("Your queue is empty", "Choose a song from Favorites, Recently played, or Playlists.")
        case "root": ("Your library is empty", "Save some music in Velvet Thorn, then choose Reload.")
        default: ("No songs yet", "Add songs to this playlist in Velvet Thorn, then choose Reload.")
        }
    }
}
