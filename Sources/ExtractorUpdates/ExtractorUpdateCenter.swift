import Foundation
import Observation
import OSLog
import YouTubeKit

enum ExtractorUpdateEvent: String, Sendable { case prepared, activated, confirmed, rolledBack, bundled, rejected, cancelled, recovered }

@MainActor @Observable
final class ExtractorUpdateCenter {
    private(set) var activeRevision: Int64?
    private(set) var highestRevision: Int64 = 0
    private(set) var pendingRevision: Int64?
    private(set) var pendingID: UUID?
    private(set) var pendingPublisherVerified = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var isStarted = false
    private(set) var needsPlaybackConfirmation = false
    private(set) var runtimeGeneration: UInt64 = 0
    private(set) var recoveredUnconfirmed = false
    var feedConfigured: Bool { feed != nil }
    var storageAvailable: Bool { store.failure == nil }

    @ObservationIgnored private let store: ExtractorUpdateStore
    @ObservationIgnored private let app: ExtractorAppCompatibility
    @ObservationIgnored private let feed: ExtractorUpdateFeed?
    @ObservationIgnored private let trustedKeys: [String: Data]
    @ObservationIgnored private var pending: ValidatedExtractorUpdate?
    @ObservationIgnored private var operation: UInt64 = 0
    @ObservationIgnored private var worker: Task<Data, Error>?
    @ObservationIgnored private let metric: (ExtractorUpdateEvent, ExtractorUpdateFailure?) -> Void
    @ObservationIgnored var onRulesChanged: ((UInt64) -> Void)?

    init(directory: URL, app: ExtractorAppCompatibility = .current, feed: ExtractorUpdateFeed? = nil,
         manualTrustedKeys: [String: Data] = [:],
         write: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) },
         metric: @escaping (ExtractorUpdateEvent, ExtractorUpdateFailure?) -> Void = { event, failure in
             Logger(subsystem: "com.agraabhi.ganabajana", category: "ExtractorUpdates")
                 .info("event=extractor_update outcome=\(event.rawValue, privacy: .public) reason=\(failure?.rawValue ?? "none", privacy: .public)")
         }) {
        self.app = app
        self.feed = feed
        let keys = manualTrustedKeys.merging(feed?.trustedKeys ?? [:]) { _, feedKey in feedKey }
        trustedKeys = keys
        store = ExtractorUpdateStore(directory: directory, app: app, trustedKeys: keys, feedKeys: feed?.trustedKeys ?? [:], write: write)
        self.metric = metric
    }

    /// Call once for the production app, before constructing resolvers. Test/preview hosts opt in explicitly.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        recoveredUnconfirmed = store.recoveredUnconfirmed
        publish()
        if store.failure != nil { reject(.storage) }
        else if recoveredUnconfirmed { metric(.recovered, nil) }
    }

    func prepareImport(from url: URL) async {
        await prepare(source: .manual) { try await ExtractorUpdateFile.importFile(url) }
    }

    func checkFeed() async {
        guard let feed else { reject(.feedNotConfigured); return }
        await prepare(source: .signedFeed) { try await feed.fetch() }
    }

    /// The receive closure is an isolated transport seam; validation and the generation fence always run here.
    func prepare(source: ExtractorUpdateSource, receive: @escaping @Sendable () async throws -> Data) async {
        guard isStarted, storageAvailable else { reject(.storage); return }
        retire()
        let generation = operation
        isBusy = true
        errorMessage = nil
        let task = Task { try await receive() }
        worker = task
        do {
            let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            guard generation == operation, !Task.isCancelled else { throw ExtractorUpdateFailure.cancelled }
            let candidate = try ExtractorUpdateValidator.validate(data, source: source, app: app,
                                                                  trustedKeys: source == .signedFeed ? feed?.trustedKeys ?? [:] : trustedKeys,
                                                                  after: store.state.highestRevision)
            pending = candidate
            pendingID = UUID()
            pendingRevision = candidate.payload.revision
            pendingPublisherVerified = candidate.publisherVerified
            metric(.prepared, nil)
        } catch {
            guard generation == operation else { return }
            reject(Self.failure(error))
        }
        if generation == operation { isBusy = false; worker = nil }
    }

    func activatePending(id: UUID, trustingManualSource: Bool) {
        guard id == pendingID, let pending else { return }
        guard pending.publisherVerified || (pending.source == .manual && trustingManualSource) else {
            reject(.untrustedKey)
            return
        }
        do {
            try store.activate(pending)
            retire()
            errorMessage = nil
            publish()
            metric(.activated, nil)
        } catch { reject(Self.failure(error)) }
    }

    /// Call only after actual media playback succeeds, with the generation captured before its extraction began.
    func confirmPlaybackSucceeded(generation: UInt64) {
        guard isStarted, needsPlaybackConfirmation, generation == runtimeGeneration,
              generation == YouTubeKitHooks.extractionCompatibility.generation, activeRevision != nil else { return }
        do {
            try store.confirmWorking()
            refresh()
            metric(.confirmed, nil)
        } catch { reject(Self.failure(error)) }
    }

    func rollback() { changeRules(event: .rolledBack) { try store.rollback() } }
    func useBundled() { changeRules(event: .bundled) { try store.useBundled() } }

    func cancel() {
        retire()
        metric(.cancelled, .cancelled)
    }

    private func changeRules(event: ExtractorUpdateEvent, action: () throws -> Void) {
        guard isStarted else { reject(.storage); return }
        retire()
        do {
            try action()
            errorMessage = nil
            publish()
            metric(event, nil)
        } catch { reject(Self.failure(error)) }
    }

    private func retire() {
        operation &+= 1
        worker?.cancel()
        worker = nil
        pending = nil
        pendingID = nil
        pendingRevision = nil
        pendingPublisherVerified = false
        isBusy = false
    }

    private func publish() {
        let rules = store.active?.payload.rules ?? .bundled
        do {
            runtimeGeneration = try YouTubeKitHooks.installExtractionCompatibility(rules).generation
            refresh()
            onRulesChanged?(runtimeGeneration)
        } catch { reject(.invalidRules) }
    }

    private func refresh() {
        activeRevision = store.active?.payload.revision
        highestRevision = store.state.highestRevision
        needsPlaybackConfirmation = store.state.active != store.state.knownGood
    }

    private func reject(_ failure: ExtractorUpdateFailure) {
        errorMessage = failure.message
        metric(failure == .cancelled ? .cancelled : .rejected, failure)
    }

    private static func failure(_ error: Error) -> ExtractorUpdateFailure {
        if error is CancellationError { return .cancelled }
        return error as? ExtractorUpdateFailure ?? .storage
    }
}
