import Foundation
import ServerFinderCore

/// A folder (usually a mounted server share) whose file names are kept in the index.
struct IndexedFolder: Codable, Identifiable, Hashable {
    var id: UUID
    /// Where it is mounted right now (or was last time), e.g. `/Volumes/Projects/Examenes`.
    var path: String
    var lastIndexedAt: Date?
    /// The shared folder it belongs to, so it's found again if macOS mounts it under another name.
    var serverAddress: ServerAddress?
    /// Its path inside that shared folder ("" for the whole share).
    var pathInShare: String?

    var isConnected: Bool { FileManager.default.fileExists(atPath: path) }

    var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var name: String { FileManager.default.displayName(atPath: path) }
    /// The key that identifies this folder's rows in the index.
    var shareKey: String { id.uuidString }

    func contains(path other: String) -> Bool {
        other == path || other.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}

/// Saves the folder list in the user's preferences.
enum IndexedFolderStorage {
    private static let key = "indexedFolders"

    static func load() -> [IndexedFolder] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([IndexedFolder].self, from: data)) ?? []
    }

    static func save(_ folders: [IndexedFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// Mounted volumes and the server shares behind them.
enum ServerVolumes {
    struct Location {
        var address: ServerAddress
        var pathInShare: String
    }

    /// Network volumes mounted right now.
    static func mounted() -> [(url: URL, address: ServerAddress)] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes.compactMap { volume in
            guard let values = try? volume.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey]),
                  values.volumeIsLocal == false,
                  let remountURL = values.volumeURLForRemounting,
                  let address = ServerAddress(remountURL)
            else { return nil }
            return (volume.standardizedFileURL, address)
        }
    }

    static func address(ofVolume volume: URL) -> ServerAddress? {
        (try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting.flatMap(ServerAddress.init)
    }

    /// Which share a mounted folder belongs to, or `nil` if it's not on a server.
    static func location(of path: String) -> Location? {
        let url = URL(fileURLWithPath: path)
        guard let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeURLForRemountingKey]),
              let volume = values.volume?.standardizedFileURL,
              let address = values.volumeURLForRemounting.flatMap(ServerAddress.init)
        else { return nil }
        let volumePath = volume.path.hasSuffix("/") ? volume.path : volume.path + "/"
        let inShare = path.hasPrefix(volumePath) ? String(path.dropFirst(volumePath.count)) : ""
        return Location(address: address, pathInShare: inShare)
    }
}
