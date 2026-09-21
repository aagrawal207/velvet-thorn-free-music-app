import UIKit
import XCTest
@testable import GanaBajana

@MainActor
final class AppAccessibilityAnnouncementsTests: XCTestCase {
    func testEachCallQueuesExactlyOneOrderedAnnouncementWithoutAFocusChangeNotification() throws {
        let platform = RecordingAnnouncementBoundary()
        let messages = ["Added to queue", "Playing next: Tum Hi Ho", "Added to queue"]

        for message in messages { AppAccessibilityAnnouncements.post(message, using: platform.boundary) }

        XCTAssertEqual(platform.pending.count, messages.count)
        XCTAssertTrue(platform.delivered.isEmpty, "Feedback waits for the menu or sheet dismissal")
        for (delay, _) in platform.pending {
            XCTAssertGreaterThan(delay, 0)
            XCTAssertLessThanOrEqual(delay, 0.5, "Dismissal must not leave feedback waiting indefinitely")
        }
        platform.deliverPending()

        XCTAssertEqual(platform.delivered.map { $0.1.string }, messages)
        for (notification, message) in platform.delivered {
            XCTAssertEqual(notification, .announcement, "Screen/layout notifications would move navigation focus")
            let queued = try XCTUnwrap(message.attribute(.accessibilitySpeechQueueAnnouncement, at: 0, effectiveRange: nil) as? Bool)
            XCTAssertTrue(queued, "A later toast must queue behind earlier speech")
        }
        platform.deliverPending()
        XCTAssertEqual(platform.delivered.count, messages.count, "Delivery does not repeat an announcement")
    }

    func testVoiceOverOffDoesNotScheduleOrPostFeedback() {
        let platform = RecordingAnnouncementBoundary()
        platform.voiceOverRunning = false

        AppAccessibilityAnnouncements.post("Added to queue", using: platform.boundary)
        platform.voiceOverRunning = true
        platform.deliverPending()

        XCTAssertTrue(platform.pending.isEmpty)
        XCTAssertTrue(platform.delivered.isEmpty)
    }

    func testVoiceOverTurningOffDuringDismissalSuppressesPendingSpeech() {
        let platform = RecordingAnnouncementBoundary()
        AppAccessibilityAnnouncements.post("Added to queue", using: platform.boundary)
        XCTAssertEqual(platform.pending.count, 1)

        platform.voiceOverRunning = false
        platform.deliverPending()

        XCTAssertTrue(platform.delivered.isEmpty)
    }

    func testEmptyFeedbackDoesNotScheduleSpeech() {
        let platform = RecordingAnnouncementBoundary()
        for message in ["", " \n\t"] { AppAccessibilityAnnouncements.post(message, using: platform.boundary) }
        XCTAssertTrue(platform.pending.isEmpty)
        XCTAssertTrue(platform.delivered.isEmpty)
    }
}

@MainActor
private final class RecordingAnnouncementBoundary {
    var voiceOverRunning = true
    var pending: [(TimeInterval, @MainActor @Sendable () -> Void)] = []
    var delivered: [(UIAccessibility.Notification, NSAttributedString)] = []

    var boundary: AppAccessibilityAnnouncements.Boundary {
        .init(isVoiceOverRunning: { self.voiceOverRunning },
              schedule: { self.pending.append(($0, $1)) },
              send: { self.delivered.append(($0, $1)) })
    }

    func deliverPending() {
        let scheduled = pending
        pending.removeAll()
        for (_, action) in scheduled { action() }
    }
}
