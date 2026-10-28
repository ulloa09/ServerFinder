import Foundation

/// One file or folder found under a share root.
public struct FileRecord: Sendable, Hashable {
    /// Path relative to the share root, without a leading slash (e.g. `2024/Reports/Budget.xlsx`).
    public var relativePath: String
    public var name: String
    public var isDirectory: Bool
    /// Size in bytes; always 0 for folders.
    public var size: Int64
    public var modifiedAt: Date?

    public init(relativePath: String, name: String, isDirectory: Bool, size: Int64, modifiedAt: Date?) {
        self.relativePath = relativePath
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modifiedAt = modifiedAt
    }
}
