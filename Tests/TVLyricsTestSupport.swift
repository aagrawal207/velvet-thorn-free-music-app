import Observation
import UIKit
@testable import GanaBajana

@MainActor @Observable
final class TVLyricsTestPlayback {
    var track: Track? = LyricsTestFixtures.track
    var position: TimeInterval = 0
    var duration: TimeInterval = 200
    var offset: TimeInterval = 0
    var idleDisabled = false
    var idleWrites: [Bool] = []

    func controller() -> TVLyricsController {
        TVLyricsController(track: { self.track }, position: { self.position }, duration: { self.duration },
                           lyricsOffset: { _ in self.offset },
                           idleTimer: TVLyricsIdleTimer(read: { self.idleDisabled }, write: {
                               self.idleDisabled = $0
                               self.idleWrites.append($0)
                           }))
    }

    func document(kind: LyricsKind = .synced, plain: String? = nil) -> LyricsDocument {
        LyricsDocument(trackID: track?.id ?? "missing", kind: kind,
                       lines: kind == .synced ? [LyricLine(id: 0, time: 2, text: "First test line"),
                                                LyricLine(id: 1, time: 5, text: "Second test line"),
                                                LyricLine(id: 2, time: 9, text: "Third test line")] : [],
                       plainText: plain)
    }
}
