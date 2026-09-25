#if DEBUG
import SwiftUI
import WidgetKit

private struct MusicWidgetPreviewFamilyKey: EnvironmentKey {
    static var defaultValue: WidgetFamily? { nil }
}

extension EnvironmentValues {
    // WidgetKit's family is read-only outside its host; app previews need an explicit canvas context.
    var musicWidgetPreviewFamily: WidgetFamily? {
        get { self[MusicWidgetPreviewFamilyKey.self] }
        set { self[MusicWidgetPreviewFamilyKey.self] = newValue }
    }
}
#endif
