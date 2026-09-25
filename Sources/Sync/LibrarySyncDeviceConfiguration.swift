import Foundation

struct LibrarySyncDeviceConfiguration: Codable, Equatable, Sendable {
    var version = 1
    var replicaID = UUID()
    var enabled = true
    var boundAccount: String?
    var lastSyncDate: Date?
}

@MainActor
protocol LibrarySyncConfigurationPersisting: AnyObject {
    func load() throws -> LibrarySyncDeviceConfiguration
    func save(_ configuration: LibrarySyncDeviceConfiguration) throws
}

@MainActor
final class LibrarySyncDeviceConfigurationStore: LibrarySyncConfigurationPersisting {
    private let fileURL: URL?
    private var expected: Data?
    private var configuration: LibrarySyncDeviceConfiguration?
    private static let maximumBytes = 64 * 1024

    init(fileURL: URL?) { self.fileURL = fileURL }

    func load() throws -> LibrarySyncDeviceConfiguration {
        if let configuration {
            guard let fileURL, try read(fileURL) == expected else { throw LibraryStorageError.changedOnDisk }
            return configuration
        }
        guard let fileURL else { throw LibraryStorageError.invalidDirectory }
        let data = try read(fileURL)
        let loaded: LibrarySyncDeviceConfiguration
        if let data {
            let version = try LibrarySyncCodec.decode(LibraryPersistence.VersionHeader.self, from: data).version
            guard version <= 1 else { throw LibrarySyncError.newerVersion }
            guard version == 1 else { throw LibrarySyncError.unsupportedVersion }
            loaded = try LibrarySyncCodec.decode(LibrarySyncDeviceConfiguration.self, from: data)
            guard loaded.boundAccount.map({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 }) ?? true,
                  loaded.lastSyncDate.map(LibraryValidation.isValidDate) ?? true else {
                throw LibrarySyncError.invalidData("device sync configuration")
            }
        } else {
            loaded = LibrarySyncDeviceConfiguration()
        }
        expected = data
        configuration = loaded
        return loaded
    }

    func save(_ configuration: LibrarySyncDeviceConfiguration) throws {
        guard configuration.version <= 1 else { throw LibrarySyncError.newerVersion }
        guard configuration.version == 1 else { throw LibrarySyncError.unsupportedVersion }
        guard configuration.boundAccount.map({ !$0.isEmpty && $0.utf8.count <= 16 * 1024 }) ?? true,
              configuration.lastSyncDate.map(LibraryValidation.isValidDate) ?? true else {
            throw LibrarySyncError.invalidData("device sync configuration")
        }
        _ = try load()
        guard let fileURL else { throw LibraryStorageError.invalidDirectory }
        guard try read(fileURL) == expected else { throw LibraryStorageError.changedOnDisk }
        let data = try LibrarySyncCodec.encode(configuration)
        guard data.count <= Self.maximumBytes else { throw LibrarySyncError.tooLarge }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try directory.setResourceValues(resources)
        #if os(iOS)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: fileURL, options: .atomic)
        #endif
        expected = data
        self.configuration = configuration
    }

    private func read(_ url: URL) throws -> Data? {
        do { return try LibrarySyncFileIO.readBounded(url, maximumBytes: Self.maximumBytes) }
        catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile { return nil }
    }
}
