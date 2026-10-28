import Foundation

/// A folder (usually a mounted server share) whose file names are kept in the index.
struct IndexedFolder: Codable, Identifiable, Hashable {
    var id: UUID
    var path: String
    var lastIndexedAt: Date?

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
