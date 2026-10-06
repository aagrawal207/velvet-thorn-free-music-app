import SwiftUI

extension View {
    /// Mac Catalyst builds sheet and cover hosts without the presenting window's environment objects,
    /// so every presentation re-supplies the model; iOS inherits the same values and is unaffected.
    func appPresentationEnvironment(_ model: MusicAppModel) -> some View {
        environment(model)
            .environment(\.momentMixController, model.momentMixes)
    }
}
