import AVFoundation
import CoreMotion
import Foundation
import Observation

enum MomentAudioRoute {
    /// Bluetooth A2DP/HFP can be speakers or a car; names and identifiers are not reliable activity evidence.
    static func classify(_ ports: [AVAudioSession.Port]) -> MomentRoute {
        if ports.contains(.carAudio) { return .car }
        if ports.contains(.headphones) { return .headphones }
        return .general
    }

    @MainActor static func current() -> MomentRoute {
        classify(AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType))
    }
}

@MainActor @Observable
final class MomentMotionMonitor {
    private(set) var status = "Off"
    @ObservationIgnored private var manager: CMMotionActivityManager?
    @ObservationIgnored private var activeAt: Date?
    @ObservationIgnored private var generation = UUID()

    var isAvailable: Bool {
        CMMotionActivityManager.isActivityAvailable()
            && Bundle.main.object(forInfoDictionaryKey: "NSMotionUsageDescription") is String
    }

    /// Only the explicit Settings action may pass allowPrompt; launch and history changes never request access.
    func configure(enabled: Bool, allowPrompt: Bool = false) {
        if !enabled {
            stop()
            status = "Off"
            return
        }
        guard isAvailable else { stop(); status = "Unavailable"; return }
        let authorization = CMMotionActivityManager.authorizationStatus()
        guard authorization == .authorized || (authorization == .notDetermined && allowPrompt) else {
            stop()
            status = authorization == .notDetermined ? "Not Requested" : "Access Off"
            return
        }
        guard manager == nil else { return }
        let manager = CMMotionActivityManager()
        self.manager = manager
        let generation = self.generation
        status = "Waiting for Activity"
        manager.startActivityUpdates(to: .main) { [weak self] activity in
            let startedAt = activity?.startDate
            let active = activity.map {
                $0.confidence == .high && !$0.automotive && ($0.walking || $0.running || $0.cycling)
            } ?? false
            Task { @MainActor [weak self] in
                guard let self, self.generation == generation else { return }
                self.activeAt = active ? startedAt : nil
                self.status = CMMotionActivityManager.authorizationStatus() == .authorized ? "On" : "Access Off"
            }
        }
    }

    func route(_ route: MomentRoute, now: Date) -> MomentRoute {
        guard route != .car, let activeAt, now >= activeAt, now.timeIntervalSince(activeAt) <= 120,
              CMMotionActivityManager.authorizationStatus() == .authorized else { return route }
        return .active
    }

    func stop() {
        generation = UUID()
        manager?.stopActivityUpdates()
        manager = nil
        activeAt = nil
        status = "Off"
    }

    isolated deinit { manager?.stopActivityUpdates() }
}
