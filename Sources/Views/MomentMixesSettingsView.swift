import SwiftUI

@MainActor
struct MomentMixesSettingsView: View {
    @Environment(MusicAppModel.self) private var model
    let controller: MomentMixController

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { controller.store.snapshot.preferences.learningEnabled },
                                     set: { controller.setLearningEnabled($0) })) {
                    SettingsRowLabel(title: "Learn Moment Mixes", systemImage: "clock.arrow.circlepath")
                        .settingsRowTarget()
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .accessibilityIdentifier("settings.moments.learning")
            } header: {
                Text("Learning")
            } footer: {
                SettingsFooter(id: "settings.moments.learning.description") {
                    Text("Mixes appear after listening in a similar context on at least 3 days. Time, weekday and supported audio routes stay on this device. Turning learning off clears learned moments.")
                    if !controller.store.historyEnabled {
                        Text("Learning is paused while Save Listening History is off.")
                    }
                }
            }
            .settingsSectionRows()

            Section {
                Toggle(isOn: Binding(get: { controller.store.snapshot.preferences.motionEnabled },
                                     set: { controller.setMotionEnabled($0) })) {
                    SettingsRowLabel(title: "Use Motion Activity", systemImage: "figure.walk")
                        .settingsRowTarget()
                }
                .toggleStyle(CompactSwitchToggleStyle())
                .disabled(!controller.canEnableMotion && !controller.store.snapshot.preferences.motionEnabled)
                .accessibilityIdentifier("settings.moments.motion")
            } header: {
                Text("Optional Activity")
            } footer: {
                SettingsFooter(id: "settings.moments.motion.description") {
                    Text("Allow motion access to recognize active listening. Headphones alone don’t imply exercise. No location access is used.")
                    Text(controller.motion.status)
                }
            }
            .settingsSectionRows()

            Section {
                if controller.settingsContexts.isEmpty {
                    Text("Your recurring moments will appear here.")
                        .foregroundStyle(AppTheme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(minHeight: 44)
                }
                ForEach(controller.settingsContexts) { context in
                    Toggle(isOn: Binding(get: { !controller.store.snapshot.preferences.disabledMixIDs.contains(context.id) },
                                         set: { controller.setMixEnabled($0, context: context) })) {
                        SettingsRowLabel(title: context.title, systemImage: context.symbol)
                            .settingsRowTarget()
                    }
                    .toggleStyle(CompactSwitchToggleStyle())
                    .accessibilityIdentifier("settings.moments.mix.\(context.id)")
                }
            } header: {
                Text("Your Moments")
            } footer: {
                SettingsFooter(id: "settings.moments.mixes.description") {
                    Text("Hide any mix from Home. Each mix needs at least 3 available songs. Clear Listening History also clears moment data and pending learning.")
                }
            }
            .settingsSectionRows()

            if let error = controller.store.errorMessage {
                Section {
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Button { controller.retryStorage() } label: {
                        SettingsRowLabel(title: "Try Again", systemImage: "arrow.clockwise").settingsRowTarget()
                    }
                    .accessibilityIdentifier("settings.moments.retry")
                }
                .settingsSectionRows()
            }
        }
        .settingsPageChrome("Moment Mixes", model: model)
        .accessibilityIdentifier("settings.moments")
    }
}
