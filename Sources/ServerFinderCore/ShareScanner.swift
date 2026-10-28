import Foundation

public enum ScanError: Error, Equatable {
    /// The root folder doesn't exist or isn't a folder (usually: the share isn't mounted).
    case rootUnavailable(path: String)
}

/// Walks a folder tree and emits every file and folder in it, in batches.
///
/// Only reads from the file system. Hidden files and the contents of packages are skipped,
/// and folders that can't be read are skipped without stopping the scan.
public struct ShareScanner: Sendable {
    public var batchSize: Int

    public init(batchSize: Int = 500) {
        self.batchSize = batchSize
    }

    /// Scans `root` on a background thread. Cancelling the consuming task stops the scan.
    public func scan(root: URL) -> AsyncThrowingStream<[FileRecord], any Error> {
        let batchSize = batchSize
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    try Self.walk(root: root, batchSize: batchSize) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
    ]

    static func walk(root: URL, batchSize: Int, emit: ([FileRecord]) -> Void) throws {
        let root = root.standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let enumerator = FileManager.default.enumerator(
                  at: root,
                  includingPropertiesForKeys: resourceKeys,
                  options: [.skipsHiddenFiles, .skipsPackageDescendants],
                  errorHandler: { _, _ in true }
              )
        else {
            throw ScanError.rootUnavailable(path: root.path)
        }

        let keySet = Set(resourceKeys)
        var batch: [FileRecord] = []
        batch.reserveCapacity(batchSize)
        // Names of the folders above the current item, by depth. Building relative paths from
        // these avoids comparing path prefixes, which differ for symlinked roots (/var vs /private/var).
        var ancestors: [String] = []

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            let name = values.name ?? url.lastPathComponent
            let isDirectory = values.isDirectory ?? false
            ancestors.removeSubrange(min(enumerator.level - 1, ancestors.count)...)
            let relativePath = (ancestors + [name]).joined(separator: "/")
            if isDirectory { ancestors.append(name) }
            batch.append(FileRecord(
                relativePath: relativePath,
                name: name,
                isDirectory: isDirectory,
                size: isDirectory ? 0 : Int64(values.fileSize ?? 0),
                modifiedAt: values.contentModificationDate
            ))
            if batch.count >= batchSize {
                emit(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !batch.isEmpty { emit(batch) }
    }
}
