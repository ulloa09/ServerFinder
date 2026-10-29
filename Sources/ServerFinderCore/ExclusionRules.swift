import Foundation

/// Names (or paths) to leave out of the index.
///
/// A pattern matches an item's name, ignoring case: `Thumbs.db`, or with wildcards, `~$*`
/// (`*` is any text, `?` one character). A pattern containing `/` matches the item's path
/// inside the shared folder instead, e.g. `Backups/Old`. Excluded folders aren't opened at all.
public struct ExclusionRules: Sendable, Equatable {
    public let patterns: [String]

    private let exactNames: Set<String>
    private let wildcardNames: [[Character]]
    private let exactPaths: Set<String>
    private let wildcardPaths: [[Character]]

    /// Junk and system items found on Windows file servers.
    public static let windowsServerDefaults = ExclusionRules(patterns: [
        "$RECYCLE.BIN",
        "System Volume Information",
        "~snapshot",
        "Thumbs.db",
        "desktop.ini",
        "~$*",
    ])

    public static let none = ExclusionRules(patterns: [])

    public init(patterns: [String]) {
        var cleaned: [String] = []
        for pattern in patterns {
            let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard !trimmed.isEmpty, !cleaned.contains(where: { $0.lowercased() == trimmed.lowercased() }) else { continue }
            cleaned.append(trimmed)
        }
        self.patterns = cleaned

        var exactNames: Set<String> = [], wildcardNames: [[Character]] = []
        var exactPaths: Set<String> = [], wildcardPaths: [[Character]] = []
        for pattern in cleaned.map({ $0.lowercased() }) {
            let isPath = pattern.contains("/")
            let hasWildcard = pattern.contains("*") || pattern.contains("?")
            switch (isPath, hasWildcard) {
            case (false, false): exactNames.insert(pattern)
            case (false, true): wildcardNames.append(Array(pattern))
            case (true, false): exactPaths.insert(pattern)
            case (true, true): wildcardPaths.append(Array(pattern))
            }
        }
        self.exactNames = exactNames
        self.wildcardNames = wildcardNames
        self.exactPaths = exactPaths
        self.wildcardPaths = wildcardPaths
    }

    public static func == (lhs: ExclusionRules, rhs: ExclusionRules) -> Bool {
        lhs.patterns == rhs.patterns
    }

    /// Whether the item at `relativePath` (inside the shared folder) should be left out.
    public func excludes(name: String, relativePath: String) -> Bool {
        let name = name.lowercased()
        if exactNames.contains(name) { return true }
        if !wildcardNames.isEmpty {
            let characters = Array(name)
            if wildcardNames.contains(where: { Self.matches($0, characters) }) { return true }
        }
        guard !exactPaths.isEmpty || !wildcardPaths.isEmpty else { return false }
        let path = relativePath.lowercased()
        if exactPaths.contains(path) { return true }
        let characters = Array(path)
        return wildcardPaths.contains { Self.matches($0, characters) }
    }

    /// `*` matches any run of characters, `?` exactly one.
    private static func matches(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var lastStar: Int?, textAtStar = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                lastStar = p
                textAtStar = t
                p += 1
            } else if let star = lastStar {
                // Let the last * absorb one more character and retry.
                p = star + 1
                textAtStar += 1
                t = textAtStar
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
