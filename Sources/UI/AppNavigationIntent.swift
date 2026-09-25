import SwiftUI

@MainActor
enum AppNavigationIntent {
    static func perform(in model: MusicAppModel, _ action: () -> Void) {
        model.cancelPendingArtistLookup()
        model.dismissSearchKeyboard()
        action()
    }

    static func binding<Value: Equatable>(_ source: Binding<Value>, in model: MusicAppModel,
                                          isCurrent: @escaping () -> Bool = { true }) -> Binding<Value> {
        binding(source, in: model, identity: { $0 }, isCurrent: isCurrent)
    }

    static func binding<Value, Identity: Equatable>(_ source: Binding<Value>, in model: MusicAppModel,
                                                   identity: @escaping (Value) -> Identity,
                                                   isCurrent: @escaping () -> Bool = { true }) -> Binding<Value> {
        Binding(get: { source.wrappedValue }, set: { value, transaction in
            if identity(source.wrappedValue) != identity(value), isCurrent() { model.cancelPendingArtistLookup() }
            // A delayed dismissal must not consume the focus request from a newer Search-tab reselect.
            source.transaction(transaction).wrappedValue = value
        })
    }
}

@MainActor
struct AppNavigationLink<Destination: View, Label: View>: View {
    @Environment(MusicAppModel.self) private var model
    @State private var isActive = false
    @State private var activationTab: AppTab?
    private let destination: Destination
    private let label: Label

    init(@ViewBuilder destination: () -> Destination, @ViewBuilder label: () -> Label) {
        self.destination = destination()
        self.label = label()
    }

    var body: some View {
        // A native selection binding covers activation and Back outside the root's typed collection path.
        NavigationLink(destination: destination, isActive: selection) { label }
            .onChange(of: resetGeneration) { _, _ in
                guard isActive else { return }
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                $isActive.transaction(transaction).wrappedValue = false
                activationTab = nil
            }
    }

    private var resetGeneration: UUID? {
        switch activationTab ?? model.selectedTab {
        case .search: model.searchRootGeneration
        case .library: model.libraryRootGeneration
        default: nil
        }
    }

    private var selection: Binding<Bool> {
        let intent = AppNavigationIntent.binding($isActive, in: model, isCurrent: { activationTab == model.selectedTab })
        return Binding(get: { intent.wrappedValue }, set: { value, transaction in
            if value, !intent.wrappedValue {
                activationTab = model.selectedTab
                model.dismissSearchKeyboard()
            }
            intent.transaction(transaction).wrappedValue = value
            if !value { activationTab = nil }
        })
    }
}

@MainActor
struct AppNavigationIntentButtonStyle<Base: PrimitiveButtonStyle>: PrimitiveButtonStyle {
    @Environment(MusicAppModel.self) private var model
    let base: Base

    init(_ base: Base) { self.base = base }

    func makeBody(configuration: Configuration) -> some View {
        // A standard Button forwards touch, keyboard and accessibility activation to the original control.
        Button(role: configuration.role) {
            AppNavigationIntent.perform(in: model) { configuration.trigger() }
        } label: {
            configuration.label
        }
        .buttonStyle(base)
    }
}
