import Foundation
import Observation
import OSLog

@MainActor @Observable
final class LyricsLoader {
    enum State {
        case loading
        case loaded(LyricsDocument)
        case failed(String)
    }

    private(set) var track: Track?
    private(set) var state: State = .loading
    private(set) var variants: [LyricsVariant] = []
    private(set) var recordingLanguage: String?
    private(set) var isDiscoveringVariants = false
    private(set) var variantMessage: String?
    @ObservationIgnored var onSelectionChanged: (@MainActor (Track, LyricsDocument?) -> Void)?
    private var generation: UInt64 = 0
    @ObservationIgnored private var choices: [ChoiceKey: (id: String, access: UInt64)] = [:]
    private var choiceAccess: UInt64 = 0

    private struct ChoiceKey: Hashable {
        let recording: LyricsRequestKey
        let language: String?
    }

    var selectedDocument: LyricsDocument? {
        guard case .loaded(let document) = state else { return nil }
        return document
    }

    func load(for track: Track, using provider: any LyricsProviding, recordingLanguage: String? = nil) async {
        guard !Task.isCancelled else { return }
        generation &+= 1
        let requestGeneration = generation
        self.track = track
        self.recordingLanguage = recordingLanguage ?? track.language.map { $0 == .hindi ? "hi" : "en" }
        state = .loading
        variants = []
        variantMessage = nil
        isDiscoveringVariants = false
        onSelectionChanged?(track, nil)
        var baselineError: (any Error)?
        var baselineDocument: LyricsDocument?
        do {
            let document = try await provider.lyrics(for: track)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            try document.validateVariant(for: track)
            baselineDocument = document
            if document.kind != .unavailable || !(provider is any LyricsVariantsProviding) { apply([document], for: track) }
            if document.kind == .instrumental { return }
        } catch is CancellationError {
            return
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            baselineError = error
        }
        guard let provider = provider as? any LyricsVariantsProviding else {
            if let baselineError { state = .failed(baselineError.localizedDescription) }
            return
        }
        isDiscoveringVariants = true
        defer { if requestGeneration == generation { isDiscoveringVariants = false } }
        do {
            let documents = try await provider.lyricVariants(for: track)
            try Task.checkCancellation()
            guard requestGeneration == generation else { return }
            guard documents.count <= 8 else { throw MusicServiceError.invalidResponse }
            for document in documents { try document.validateVariant(for: track) }
            if !documents.isEmpty { apply(documents, for: track) }
            else if let baselineDocument { apply([baselineDocument], for: track) }
            else if let baselineError { throw baselineError }
        } catch {
            guard requestGeneration == generation, !Task.isCancelled, !(error is CancellationError) else { return }
            if let document = selectedDocument, document.kind != .unavailable {
                variantMessage = "Other lyric versions couldn’t be checked. Try again."
            } else {
                state = .failed(LyricsLookupError.sourcesFailed.localizedDescription)
                onSelectionChanged?(track, nil)
            }
        }
    }

    /// Coordinators clear the projection immediately on a track change, including while the lyrics sheet is closed.
    func clear() {
        generation &+= 1
        let previous = track
        track = nil
        recordingLanguage = nil
        state = .loading
        variants = []
        variantMessage = nil
        isDiscoveringVariants = false
        if let previous { onSelectionChanged?(previous, nil) }
    }

    func selectVariant(id: String, for requestedTrack: Track) {
        guard requestedTrack == track, let variant = variants.first(where: { $0.id == id }) else { return }
        choiceAccess &+= 1
        choices[ChoiceKey(recording: LyricsRequestKey(requestedTrack), language: recordingLanguage)] = (id, choiceAccess)
        while choices.count > 32 {
            guard let oldest = choices.min(by: { $0.value.access < $1.value.access }) else { break }
            choices.removeValue(forKey: oldest.key)
        }
        state = .loaded(variant.document)
        onSelectionChanged?(requestedTrack, variant.document)
        LyricsDiagnostics.logger.debug("variantSelected=1 script=\(variant.script.rawValue, privacy: .public)")
    }

    private func apply(_ documents: [LyricsDocument], for track: Track) {
        var seen = Set<String>()
        var candidates = documents.filter { $0.kind == .plain || $0.kind == .synced }
        if let current = selectedDocument, current.kind == .plain || current.kind == .synced,
           !candidates.contains(where: { $0.samePublishedContent(as: current) }) { candidates.insert(current, at: 0) }
        variants = Array(candidates.map(LyricsVariant.init).filter { seen.insert($0.id).inserted }.prefix(8))
        let choice = choices[ChoiceKey(recording: LyricsRequestKey(track), language: recordingLanguage)]?.id
        let selected = variants.first(where: { $0.id == choice })
            ?? variants.first(where: { $0.script.isOriginalScript(for: recordingLanguage) })
            ?? variants.first
        if let document = selected?.document ?? documents.first {
            state = .loaded(document)
            onSelectionChanged?(track, document)
        }
    }
}
