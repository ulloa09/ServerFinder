import Foundation

/// Which app opens each file type, for files opened from ServerFinder.
/// Types without a rule open with the Mac's default app.
public struct OpenWithRules: Sendable, Equatable, Codable {
    /// File extension (lowercase, no dot) → app bundle identifier.
    public private(set) var appsByExtension: [String: String]

    public init(_ appsByExtension: [String: String] = [:]) {
        self.appsByExtension = [:]
        for (fileExtension, bundleID) in appsByExtension {
            set(bundleID, forExtension: fileExtension)
        }
    }

    /// Extensions with a rule, alphabetically.
    public var extensions: [String] { appsByExtension.keys.sorted() }

    /// The app chosen for this file, or `nil` to use the Mac's default.
    public func appBundleID(forFileNamed name: String, isDirectory: Bool) -> String? {
        guard !isDirectory else { return nil }
        let fileExtension = (name as NSString).pathExtension.lowercased()
        guard !fileExtension.isEmpty else { return nil }
        return appsByExtension[fileExtension]
    }

    public mutating func set(_ bundleID: String, forExtension fileExtension: String) {
        guard let key = Self.normalizedExtension(fileExtension), !bundleID.isEmpty else { return }
        appsByExtension[key] = bundleID
    }

    public mutating func remove(extension fileExtension: String) {
        guard let key = Self.normalizedExtension(fileExtension) else { return }
        appsByExtension[key] = nil
    }

    /// "  .PDF " → "pdf". `nil` if it isn't a plausible extension.
    public static func normalizedExtension(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutDots = trimmed.drop { $0 == "." }.lowercased()
        guard (1...15).contains(withoutDots.count),
              withoutDots.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return withoutDots
    }
}
