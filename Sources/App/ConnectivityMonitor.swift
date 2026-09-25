import Foundation
import Network
import Observation
import OSLog
import Synchronization

@MainActor @Observable
final class ConnectivityMonitor {
    enum Status: Int, Equatable, Sendable {
        case unknown, online, offline
    }

    private(set) var status: Status
    @ObservationIgnored var onChange: (@MainActor (Status) -> Void)?
    @ObservationIgnored nonisolated private let lockedStatus: Mutex<Status>
    @ObservationIgnored private let monitorsSystem: Bool
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let log = Logger(subsystem: "com.agraabhi.ganabajana", category: "Connectivity")

    init(initialStatus: Status = .unknown, monitorsSystem: Bool = true) {
        status = initialStatus
        lockedStatus = Mutex(initialStatus)
        self.monitorsSystem = monitorsSystem
    }

    nonisolated var isOffline: Bool { lockedStatus.withLock { $0 == .offline } }

    func start() {
        guard monitorsSystem, monitor == nil else { return }
        let token = UUID()
        generation = token
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let status: Status
            switch path.status {
            case .satisfied: status = .online
            case .unsatisfied: status = .offline
            case .requiresConnection: status = .unknown
            @unknown default: status = .unknown
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.setStatus(status)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.agraabhi.ganabajana.connectivity", qos: .utility))
    }

    func stop() {
        generation = UUID()
        monitor?.cancel()
        monitor = nil
    }

    func setStatus(_ status: Status) {
        guard status != self.status else { return }
        lockedStatus.withLock { $0 = status }
        self.status = status
        log.info("event=network_path status=\(status.rawValue)")
        onChange?(status)
    }

    isolated deinit { monitor?.cancel() }
}
