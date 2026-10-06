import UIKit

@MainActor
final class TVLyricsIdleTimer {
    private let read: @MainActor () -> Bool
    private let write: @MainActor (Bool) -> Void
    private var previousValue: Bool?

    init(read: @escaping @MainActor () -> Bool, write: @escaping @MainActor (Bool) -> Void) {
        self.read = read
        self.write = write
    }

    static func system() -> TVLyricsIdleTimer {
        TVLyricsIdleTimer(read: { UIApplication.shared.isIdleTimerDisabled },
                          write: { UIApplication.shared.isIdleTimerDisabled = $0 })
    }

    func update(isPresenting: Bool) {
        if isPresenting {
            guard previousValue == nil else { return }
            previousValue = read()
            write(true)
        } else if let previousValue {
            self.previousValue = nil
            write(previousValue)
        }
    }
}
