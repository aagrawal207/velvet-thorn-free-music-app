import AppIntents
import Foundation

struct MixWidgetOptionsProvider: DynamicOptionsProvider {
    func results() async throws -> IntentItemCollection<String> {
        IntentItemCollection(sections: [IntentItemSection(items: [
            IntentItem(GeneratedPlaylistKind.dailyMix.rawValue, title: "Daily Mix"),
            IntentItem(GeneratedPlaylistKind.discoverWeekly.rawValue, title: "Discover Weekly")
        ])])
    }

    func defaultResult() async -> String? { GeneratedPlaylistKind.dailyMix.rawValue }
}

struct MixWidgetConfigurationIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource { "Mix" }
    static var description: IntentDescription { IntentDescription("Choose which saved mix to show.") }

    // Stable raw values avoid AppEnum resolution falling back to the default on the supported WidgetKit runtime.
    @Parameter(title: "Mix", optionsProvider: MixWidgetOptionsProvider())
    var selection: String?

    var mixKind: GeneratedPlaylistKind { selection.flatMap(GeneratedPlaylistKind.init(rawValue:)) ?? .dailyMix }

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$selection)")
    }
}
