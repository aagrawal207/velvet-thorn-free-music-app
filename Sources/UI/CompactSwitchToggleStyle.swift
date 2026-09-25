import SwiftUI

struct CompactSwitchToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 12) {
                configuration.label
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: .constant(configuration.isOn)) { EmptyView() }
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .scaleEffect(0.8)
                    .frame(width: 52, height: 44)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 44)
            .contentShape([.interaction, .accessibility], Rectangle())
        }
        .buttonStyle(.plain)
        // The smaller native switch keeps the whole row's touch target and standard switch accessibility actions.
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
                .frame(minHeight: 44)
                .contentShape(.accessibility, Rectangle())
                .accessibilityElement(children: .combine)
        }
    }
}
