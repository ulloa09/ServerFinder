import Foundation

/// Identifies a shared folder by where it lives on the network (e.g. `smb://fileserver/projects`),
/// independent of where macOS mounts it (`/Volumes/Projects` or `/Volumes/Projects-1`).
public struct ServerAddress: Sendable, Hashable, Codable, CustomStringConvertible {
    /// Lowercased, without user name, password or trailing slash.
    public let normalized: String

    /// `url` is a volume's remount URL, such as `smb://admin@fileserver/Projects`.
    /// Returns `nil` for anything that isn't a network address.
    public init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme != "file",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        // SMB share and folder names aren't case-sensitive.
        let path = components.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        normalized = "\(scheme)://\(host)\(port)" + (path.isEmpty ? "" : "/\(path)")
    }

    public var description: String { normalized }
}

/// When a folder is due for its next automatic scan.
public enum RescanSchedule {
    /// `interval` of `nil` means automatic rescans are off.
    public static func isDue(lastIndexedAt: Date?, interval: TimeInterval?, now: Date = .now) -> Bool {
        guard let lastIndexedAt else { return true }
        guard let interval else { return false }
        return now.timeIntervalSince(lastIndexedAt) >= interval
    }
}
