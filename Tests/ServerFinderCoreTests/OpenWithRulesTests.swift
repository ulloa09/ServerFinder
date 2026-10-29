import Foundation
import Testing
@testable import ServerFinderCore

@Suite struct OpenWithRulesTests {
    let acrobat = "com.adobe.Acrobat.Pro"
    let preview = "com.apple.Preview"
    let word = "com.microsoft.Word"

    @Test func findsTheAppForAFileIgnoringCase() {
        let rules = OpenWithRules(["pdf": acrobat])

        #expect(rules.appBundleID(forFileNamed: "Plano.pdf", isDirectory: false) == acrobat)
        #expect(rules.appBundleID(forFileNamed: "PLANO.PDF", isDirectory: false) == acrobat)
        #expect(rules.appBundleID(forFileNamed: "Informe.docx", isDirectory: false) == nil)
    }

    @Test func usesOnlyTheLastExtension() {
        let rules = OpenWithRules(["pdf": acrobat])

        #expect(rules.appBundleID(forFileNamed: "Reporte.pdf.zip", isDirectory: false) == nil)
        #expect(rules.appBundleID(forFileNamed: "Reporte.final.pdf", isDirectory: false) == acrobat)
    }

    @Test func noRuleForFilesWithoutAnExtensionOrForFolders() {
        let rules = OpenWithRules(["pdf": acrobat])

        #expect(rules.appBundleID(forFileNamed: "LEEME", isDirectory: false) == nil)
        #expect(rules.appBundleID(forFileNamed: "Planos.pdf", isDirectory: true) == nil)
    }

    @Test(arguments: [("pdf", "pdf"), (".PDF", "pdf"), ("  docx ", "docx"), ("..xlsx", "xlsx")])
    func acceptsExtensionsHoweverTheyAreTyped(typed: String, stored: String) {
        var rules = OpenWithRules()
        rules.set(acrobat, forExtension: typed)

        #expect(rules.appsByExtension == [stored: acrobat])
    }

    @Test(arguments: ["", ".", "   ", "a b", "pdf/x", "waytoolongextension"])
    func ignoresThingsThatAreNotExtensions(typed: String) {
        var rules = OpenWithRules()
        rules.set(acrobat, forExtension: typed)

        #expect(rules.appsByExtension.isEmpty)
    }

    @Test func replacingAndRemovingRules() {
        var rules = OpenWithRules(["pdf": acrobat, "docx": word])

        rules.set(preview, forExtension: "PDF")
        #expect(rules.appsByExtension == ["pdf": preview, "docx": word])

        rules.remove(extension: ".docx")
        #expect(rules.appsByExtension == ["pdf": preview])
        #expect(rules.extensions == ["pdf"])
    }

    @Test func survivesSavingAndLoading() throws {
        let rules = OpenWithRules(["pdf": acrobat, "docx": word])

        let data = try JSONEncoder().encode(rules)
        #expect(try JSONDecoder().decode(OpenWithRules.self, from: data) == rules)
    }
}
