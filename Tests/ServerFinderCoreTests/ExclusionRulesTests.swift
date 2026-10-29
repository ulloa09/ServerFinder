import Testing
@testable import ServerFinderCore

@Suite struct ExclusionRulesTests {
    private func excludes(_ patterns: [String], _ path: String) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return ExclusionRules(patterns: patterns).excludes(name: name, relativePath: path)
    }

    @Test(arguments: [
        "$RECYCLE.BIN", "System Volume Information", "~snapshot", "Thumbs.db", "desktop.ini",
        "Docs/Thumbs.db", "Docs/DESKTOP.INI", "Ventas/~$Cotización.docx", "~$Libro1.xlsx",
    ])
    func windowsDefaultsCoverServerJunk(path: String) {
        #expect(ExclusionRules.windowsServerDefaults.excludes(
            name: String(path.split(separator: "/").last!), relativePath: path
        ))
    }

    @Test(arguments: ["Informe.docx", "Recycle notes.txt", "Thumbs.db.txt", "my~$file.txt", "Desktop"])
    func windowsDefaultsKeepRealFiles(path: String) {
        #expect(!ExclusionRules.windowsServerDefaults.excludes(name: path, relativePath: path))
    }

    @Test func namesIgnoreCase() {
        #expect(excludes(["thumbs.db"], "A/THUMBS.DB"))
    }

    @Test func wildcards() {
        #expect(excludes(["*.tmp"], "Work/build.tmp"))
        #expect(!excludes(["*.tmp"], "Work/build.tmp.pdf"))
        #expect(excludes(["Backup ????"], "Backup 2024"))
        #expect(!excludes(["Backup ????"], "Backup 24"))
        #expect(excludes(["*copia*"], "Informe (copia 2).docx"))
        #expect(excludes(["a*b*c"], "aXXbYYc"))
        #expect(!excludes(["a*b*c"], "aXXbYY"))
    }

    @Test func patternsWithSlashMatchPaths() {
        #expect(excludes(["Respaldos/Antiguos"], "Respaldos/Antiguos"))
        #expect(!excludes(["Respaldos/Antiguos"], "Otros/Antiguos"))
        #expect(excludes(["*/Antiguos"], "Otros/Antiguos"))
        #expect(excludes(["/Respaldos/Antiguos/"], "Respaldos/Antiguos"), "leading and trailing slashes are ignored")
    }

    @Test func cleansUpPatterns() {
        let rules = ExclusionRules(patterns: ["  Thumbs.db ", "", "thumbs.db", "   ", "*.tmp"])
        #expect(rules.patterns == ["Thumbs.db", "*.tmp"])
    }

    @Test func noRulesExcludeNothing() {
        #expect(!ExclusionRules.none.excludes(name: "anything", relativePath: "anything"))
    }
}
