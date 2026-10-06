import Foundation
import Synchronization

struct BackgroundDownloadTask: Sendable {
    let id: Int
    let token: UUID?
    let allowsCellular: Bool
}

enum BackgroundDownloadEvent: Sendable {
    case progress(UUID, written: Int64, expected: Int64, taskID: Int? = nil)
    case delivered(UUID, taskID: Int? = nil)
    case failed(UUID, BackgroundDownloadFailure, taskID: Int? = nil)
    case completed(Int)
    case drained
}

protocol BackgroundDownloadSession: Sendable {
    var events: AsyncStream<BackgroundDownloadEvent> { get }
    func allTasks() async -> [BackgroundDownloadTask]
    func create(_ request: URLRequest, token: UUID) -> Int
    func resume(_ id: Int)
    func cancel(_ id: Int)
}

/// Only this delegate touches URLSession's ephemeral delivery URL, before returning from the callback.
final class SystemBackgroundDownloadSession: NSObject, BackgroundDownloadSession, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.agraabhi.ganabajana.downloads.v1"
    let events: AsyncStream<BackgroundDownloadEvent>
    private let feed: AsyncStream<BackgroundDownloadEvent>.Continuation
    private let staging: BackgroundDownloadStaging
    private let session = Mutex<URLSession?>(nil)
    private let tasks = Mutex<[Int: URLSessionTask]>([:])
    private let percentages = Mutex<[Int: Int]>([:])

    init(staging: BackgroundDownloadStaging) {
        self.staging = staging
        let channel = AsyncStream<BackgroundDownloadEvent>.makeStream()
        events = channel.stream
        feed = channel.continuation
        super.init()
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Per-request policy is durable in the OS task and can differ across the same stable session.
        config.allowsCellularAccess = true
        config.allowsExpensiveNetworkAccess = true
        config.waitsForConnectivity = true
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForResource = 6 * 3_600
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        return config
    }

    private func connectedSession() -> URLSession {
        session.withLock { value in
            if let value { return value }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.name = "com.agraabhi.ganabajana.download-delivery"
            let created = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: queue)
            value = created
            return created
        }
    }

    func allTasks() async -> [BackgroundDownloadTask] {
        let existing = await connectedSession().allTasks
        tasks.withLock { table in for task in existing { table[task.taskIdentifier] = task } }
        return existing.map { BackgroundDownloadTask(id: $0.taskIdentifier, token: $0.taskDescription.flatMap(UUID.init(uuidString:)),
                                                     allowsCellular: $0.originalRequest?.allowsCellularAccess ?? true) }
    }

    func create(_ request: URLRequest, token: UUID) -> Int {
        let task = connectedSession().downloadTask(with: request)
        task.taskDescription = token.uuidString
        tasks.withLock { $0[task.taskIdentifier] = task }
        return task.taskIdentifier
    }

    func resume(_ id: Int) { tasks.withLock { $0[id] }?.resume() }
    func cancel(_ id: Int) {
        tasks.withLock { $0.removeValue(forKey: id) }?.cancel()
        percentages.withLock { _ = $0.removeValue(forKey: id) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let token = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { downloadTask.cancel(); return }
        if totalBytesWritten > AudioCache.maximumFileBytes || totalBytesExpectedToWrite > AudioCache.maximumFileBytes {
            downloadTask.cancel()
            feed.yield(.failed(token, .invalidMedia, taskID: downloadTask.taskIdentifier))
            return
        }
        let percent = totalBytesExpectedToWrite > 0 ? Int(min(99, max(0, 100 * Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))) : 0
        let changed = percentages.withLock { values in
            guard values[downloadTask.taskIdentifier] != percent else { return false }
            values[downloadTask.taskIdentifier] = percent
            return true
        }
        if changed { feed.yield(.progress(token, written: totalBytesWritten, expected: totalBytesExpectedToWrite, taskID: downloadTask.taskIdentifier)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let token = downloadTask.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        do {
            try staging.receive(location, token: token, response: downloadTask.response,
                                declaredBytes: downloadTask.originalRequest?.url.flatMap(AudioDownloader.declaredLength(in:)))
            feed.yield(.delivered(token, taskID: downloadTask.taskIdentifier))
        } catch let failure as BackgroundDownloadFailure { feed.yield(.failed(token, failure, taskID: downloadTask.taskIdentifier)) }
        catch is PlaybackStreamError { feed.yield(.failed(token, .invalidMedia, taskID: downloadTask.taskIdentifier)) }
        catch { feed.yield(.failed(token, .staging, taskID: downloadTask.taskIdentifier)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        defer { feed.yield(.completed(task.taskIdentifier)) }
        tasks.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
        percentages.withLock { _ = $0.removeValue(forKey: task.taskIdentifier) }
        guard let error, let token = task.taskDescription.flatMap(UUID.init(uuidString:)) else { return }
        // NSError can contain the signed request URL and resume data; neither crosses the delivery boundary.
        let code = (error as? URLError)?.code
        feed.yield(.failed(token, code == .cancelled ? .interrupted : .transport, taskID: task.taskIdentifier))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) { feed.yield(.drained) }
}

/// Each receipt is committed after the file is synchronized. A missing receipt is never a playable delivery.
struct BackgroundDownloadStaging: Sendable {
    let directory: URL

    func media(_ token: UUID) -> URL { directory.appendingPathComponent(token.uuidString + ".part") }
    private func receipt(_ token: UUID) -> URL { directory.appendingPathComponent(token.uuidString + ".json") }

    func receive(_ temporary: URL, token: UUID, response: URLResponse?, declaredBytes: Int64?) throws {
        guard let http = response as? HTTPURLResponse else { throw BackgroundDownloadFailure.invalidMedia }
        if [401, 403, 410].contains(http.statusCode) { throw BackgroundDownloadFailure.expired }
        guard http.statusCode == 200 || http.statusCode == 206 else { throw BackgroundDownloadFailure.transport }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        guard encoding == nil || encoding == "identity" else { throw BackgroundDownloadFailure.invalidMedia }
        let ext: String
        switch http.mimeType?.lowercased() {
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "video/mp4": ext = "m4a"
        case "audio/wav", "audio/x-wav", "audio/wave", "audio/vnd.wave": ext = "wav"
        case "audio/webm": ext = "webm"
        default: throw BackgroundDownloadFailure.invalidMedia
        }
        let bytes = try Self.fileBytes(temporary)
        if let declaredBytes, bytes != declaredBytes { throw BackgroundDownloadFailure.invalidMedia }
        let length = try StreamValidation.contentLength(in: http)
        if let length, bytes != length { throw BackgroundDownloadFailure.invalidMedia }
        if http.statusCode == 206 {
            let range = try StreamValidation.contentRange(in: http)
            guard range.start == 0, range.end == bytes - 1, range.total == bytes else { throw BackgroundDownloadFailure.invalidMedia }
        } else if http.value(forHTTPHeaderField: "Content-Range") != nil { throw BackgroundDownloadFailure.invalidMedia }
        guard length != nil || declaredBytes != nil || http.statusCode == 206 else { throw BackgroundDownloadFailure.invalidMedia }
        let handle = try FileHandle(forReadingFrom: temporary)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 12) ?? Data()
        if ext == "webm" { try StreamValidation.validateWebM(response: http, prefix: prefix) }
        else if !AudioDownloader.looksLikeMedia(prefix, fileExtension: ext) { throw BackgroundDownloadFailure.invalidMedia }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BackgroundDownloadFailure.staging
        }
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        if (try? load(token)) != nil { return }
        if FileManager.default.fileExists(atPath: receipt(token).path) { try FileManager.default.removeItem(at: receipt(token)) }
        let destination = media(token)
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        var committed = false
        defer { if !committed { try? FileManager.default.removeItem(at: destination) } }
        try FileManager.default.copyItem(at: temporary, to: destination)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: destination.path)
        let durable = try FileHandle(forWritingTo: destination)
        defer { try? durable.close() }
        try durable.synchronize()
        let metadata = AudioCache.Sidecar(bytes: bytes, storedAt: Date(), fileExtension: ext)
        try JSONEncoder().encode(metadata).write(to: receipt(token), options: .atomic)
        committed = true
    }

    func load(_ token: UUID) throws -> AudioCache.Sidecar? {
        guard FileManager.default.fileExists(atPath: receipt(token).path) else { return nil }
        let url = receipt(token)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes[.size] as? NSNumber
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (size?.intValue ?? Int.max) <= 4_096 else { throw BackgroundDownloadFailure.invalidMedia }
        let metadata = try JSONDecoder().decode(AudioCache.Sidecar.self, from: Data(contentsOf: url))
        guard try Self.fileBytes(media(token)) == metadata.bytes,
              ["m4a", "wav", "webm"].contains(metadata.fileExtension ?? "") else { throw BackgroundDownloadFailure.invalidMedia }
        return metadata
    }

    func remove(_ token: UUID) {
        try? FileManager.default.removeItem(at: receipt(token))
        try? FileManager.default.removeItem(at: media(token))
    }

    func prune(keeping tokens: Set<UUID>) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        guard try FileManager.default.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw BackgroundDownloadFailure.staging
        }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard ["json", "part"].contains(url.pathExtension), let token = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !tokens.contains(token) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }

    static func fileBytes(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let bytes = (attributes[.size] as? NSNumber)?.int64Value, bytes >= 12,
              bytes <= AudioCache.maximumFileBytes else { throw BackgroundDownloadFailure.invalidMedia }
        return bytes
    }
}
