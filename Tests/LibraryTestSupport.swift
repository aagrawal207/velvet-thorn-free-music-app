import Foundation
import XCTest
@testable import GanaBajana

@MainActor
func withLibraryTestDirectory(_ body: @MainActor (URL) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("GanaBajana-LibraryTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

func libraryTestTrack(_ id: String = "song-a", artist: String = "An Artist", duration: TimeInterval? = 240) -> Track {
    Track(id: id, title: "Song \(id)", artists: [artist], duration: duration)
}

func libraryTestCalendar(timeZone: String = "UTC") -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: timeZone)!
    return calendar
}

func libraryTestDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
}
