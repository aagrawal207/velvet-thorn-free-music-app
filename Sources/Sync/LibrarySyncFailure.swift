import Foundation

enum LibrarySyncFailure: String, Hashable {
    case unavailable, timeout, network, remoteChanged, localChanged, quota, permission
    case newerVersion, unsupportedVersion, invalidData, tooLarge, localStorage, unknown, cancelled

    var isTransient: Bool {
        switch self {
        case .unavailable, .timeout, .network, .remoteChanged, .localChanged: true
        default: false
        }
    }

    static func reason(for error: any Error) -> Self {
        if error is CancellationError { return .cancelled }
        if let error = error as? LibrarySyncError {
            return switch error {
            case .unavailable: .unavailable
            case .changedDuringSync: .remoteChanged
            case .localChangedDuringSync: .localChanged
            case .newerVersion: .newerVersion
            case .unsupportedVersion: .unsupportedVersion
            case .invalidData: .invalidData
            case .tooLarge: .tooLarge
            case .localStorage: .localStorage
            case .cancelled: .cancelled
            case .accountChanged: .unknown
            }
        }
        if error is DecodingError { return .invalidData }
        if let error = error as? LibraryStorageError {
            return switch error {
            case .invalidData: .invalidData
            case .newerVersion: .newerVersion
            case .unsupportedVersion: .unsupportedVersion
            case .tooLarge: .tooLarge
            default: .localStorage
            }
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            switch cocoa.code {
            case CocoaError.Code.ubiquitousFileNotUploadedDueToQuota.rawValue: return .quota
            case CocoaError.Code.fileReadNoPermission.rawValue, CocoaError.Code.fileWriteNoPermission.rawValue: return .permission
            default: break
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return .cancelled
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return .network
            default: break
            }
        }
        return .unknown
    }

    var status: String {
        switch self {
        case .quota: "iCloud storage is full"
        case .timeout: "iCloud sync timed out"
        case .unavailable: "Waiting for iCloud Drive"
        case .network: "Waiting for a connection to iCloud"
        case .remoteChanged, .localChanged: "Waiting to merge your latest library edits"
        default: "iCloud sync needs attention"
        }
    }
}
