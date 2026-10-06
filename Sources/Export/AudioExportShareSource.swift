import LinkPresentation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// UIKit requests items on background queues; callbacks only read this immutable, Sendable snapshot.
final class AudioExportShareSource: NSObject, UIActivityItemSource, Identifiable, Sendable {
    let id = UUID()
    let export: AudioExport
    let title: String
    let previewImage: UIImage?

    init(export: AudioExport, title: String) {
        self.export = export
        self.title = title
        previewImage = export.artworkJPEG.flatMap { UIImage(data: $0) }
        super.init()
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { export.url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { export.url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        UTType.mpeg4Audio.identifier
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                thumbnailImageForActivityType activityType: UIActivity.ActivityType?,
                                suggestedSize size: CGSize) -> UIImage? { previewImage }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = export.url
        metadata.url = export.url
        if let data = export.artworkJPEG {
            let provider = NSItemProvider(item: data as NSData, typeIdentifier: UTType.jpeg.identifier)
            metadata.imageProvider = provider
            metadata.iconProvider = provider
        }
        return metadata
    }
}

@MainActor
struct AudioExportShareSheet: UIViewControllerRepresentable {
    let source: AudioExportShareSource

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [source], applicationActivities: nil)
        // The native activity may outlive the SwiftUI page; its completion closure retains the file lease.
        controller.completionWithItemsHandler = { [source] _, _, _, _ in withExtendedLifetime(source) {} }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
