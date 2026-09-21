import Foundation

enum PlaybackDeadline {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = DeadlineRace<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.install(continuation)
                let work = Task.detached(priority: Task.currentPriority) {
                    do {
                        guard !race.isFinished else { return }
                        try Task.checkCancellation()
                        race.finish(.success(try await operation()))
                    } catch { race.finish(.failure(error)) }
                }
                let timer = Task.detached {
                    do {
                        try await Task.sleep(for: .seconds(seconds))
                        race.finish(.failure(PlaybackStreamError.timedOut))
                    } catch { }
                }
                race.install([work, timer])
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }
}

// The lock protects the single completion and cancellation handoff, including cancellation before installation.
private final class DeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?
    private var continuation: CheckedContinuation<Value, Error>?
    private var tasks: [Task<Void, Never>] = []

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        let completed = result
        if completed == nil { self.continuation = continuation }
        lock.unlock()
        if let completed { continuation.resume(with: completed) }
    }

    func install(_ tasks: [Task<Void, Never>]) {
        lock.lock()
        let completed = result != nil
        if !completed { self.tasks = tasks }
        lock.unlock()
        if completed { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        let tasks = self.tasks
        self.tasks = []
        lock.unlock()
        tasks.forEach { $0.cancel() }
        continuation?.resume(with: result)
    }
}
