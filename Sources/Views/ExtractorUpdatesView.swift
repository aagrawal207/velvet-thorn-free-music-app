import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ExtractorUpdatesView: View {
    @Environment(MusicAppModel.self) private var model
    let controller: ExtractorUpdateCenter
    @State private var showsImporter = false
    @State private var showsTrustConfirmation = false
    @State private var confirmationID: UUID?
    @State private var importFailed = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Active Rules", value: controller.activeRevision.map { "Revision \($0)" } ?? "Bundled")
                    .frame(minHeight: 44)
                if controller.needsPlaybackConfirmation {
                    Text("Waiting for successful playback. An unconfirmed update returns to the last working rules when the app reopens.")
                        .foregroundStyle(.secondary)
                }
                if controller.recoveredUnconfirmed {
                    Text("An unconfirmed update was rolled back when the app reopened.")
                        .foregroundStyle(.secondary)
                }
            } header: { Text("Playback Compatibility") } footer: {
                Text("These small updates can repair supported YouTube extraction changes without reinstalling Velvet Thorn. Some changes still need an app update.")
            }

            Section {
                Button { showsImporter = true } label: {
                    Label("Import Update From Files", systemImage: "doc.badge.plus").frame(minHeight: 44)
                }
                .accessibilityIdentifier("extractorUpdates.import")
                .disabled(controller.isBusy || !controller.storageAvailable || !controller.isStarted)
                if controller.feedConfigured {
                    Button { Task { await controller.checkFeed() } } label: {
                        Label("Check Configured Feed", systemImage: "arrow.clockwise").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("extractorUpdates.check")
                    .disabled(controller.isBusy || !controller.storageAvailable || !controller.isStarted)
                }
                if controller.isBusy {
                    HStack { ProgressView(); Text("Checking update…") }.frame(minHeight: 44)
                    Button("Cancel", role: .cancel) { controller.cancel() }.frame(minHeight: 44)
                }
            } header: { Text("Get an Update") } footer: {
                Text(controller.feedConfigured
                     ? "Checks contact the configured publisher over HTTPS and require its trusted signature. No listening data, account cookies or media links are sent. Checks run only when you tap."
                     : "No trusted update feed is configured. Automatic upstream updates are unavailable. Import a compatibility file only from a source you trust.")
            }

            if let revision = controller.pendingRevision {
                Section {
                    Text("Revision \(revision) is compatible with this app.")
                    Text(controller.pendingPublisherVerified ? "Publisher signature verified." : "Publisher identity is not verified. The file’s checksum only checks its integrity.")
                        .foregroundStyle(.secondary)
                    Button { confirmationID = controller.pendingID; showsTrustConfirmation = true } label: {
                        Label("Activate Update", systemImage: "checkmark.circle").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("extractorUpdates.activate")
                    Button("Discard", role: .cancel) { controller.cancel() }.frame(minHeight: 44)
                } header: { Text("Review Update") }
            }

            if controller.activeRevision != nil {
                Section {
                    Button { controller.rollback() } label: {
                        Label("Roll Back Update", systemImage: "arrow.uturn.backward").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("extractorUpdates.rollback")
                    Button { controller.useBundled() } label: {
                        Label("Use Bundled Rules", systemImage: "shippingbox").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("extractorUpdates.bundled")
                } header: { Text("Recovery") } footer: {
                    Text("Rollback uses the last working update, or the bundled rules if none has been confirmed. It does not restart the current song.")
                }
            }
            if let message = controller.errorMessage {
                Section { Text(message).foregroundStyle(.secondary) }
            }
        }
        .settingsPageChrome("Extractor Updates", model: model)
        .accessibilityIdentifier("extractorUpdates")
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { Task { await controller.prepareImport(from: url) } }
            case .failure: importFailed = true
            }
        }
        .confirmationDialog("Activate This Update?", isPresented: $showsTrustConfirmation, titleVisibility: .visible) {
            Button(controller.pendingPublisherVerified ? "Activate Update" : "Trust Source and Activate") {
                if let confirmationID { controller.activatePending(id: confirmationID, trustingManualSource: true) }
            }
        } message: {
            Text("Compatibility rules affect future playback requests. Only continue if you trust the source of this file. You can roll back from this page.")
        }
        .alert("Could Not Open File", isPresented: $importFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Choose an accessible JSON compatibility file in Files and try again.") }
    }
}
