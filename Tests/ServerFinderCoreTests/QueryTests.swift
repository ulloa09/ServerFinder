import Testing
@testable import ServerFinderCore

@Suite struct QueryTests {
    @Test(arguments: [
        ("cotización", ["cotizacion"]),
        ("COTIZACIÓN", ["cotizacion"]),
        ("Año", ["ano"]),
        ("  acme   plano\t2024 ", ["acme", "plano", "2024"]),
        ("plano Plano PLANO", ["plano"]),
        ("final_v2.pdf", ["final_v2.pdf"]),
    ])
    func splitsAndNormalizesWords(input: String, terms: [String]) {
        #expect(Query.parse(input).terms == terms)
    }

    @Test(arguments: ["", "   ", "\t\n"])
    func blankTextIsEmpty(input: String) {
        #expect(Query.parse(input).isEmpty)
    }

    @Test func keepsTheWholeTextForExactMatches() {
        #expect(Query.parse("  Informe   Anual ").text == "informe anual")
    }

    @Test func normalizesLikeTheIndex() {
        // Names from SMB servers can arrive decomposed (e + combining accent).
        let decomposed = "Cotizacio\u{301}n"
        #expect(SearchText.normalize(decomposed) == "cotizacion")
        #expect(Query.parse(decomposed).terms == ["cotizacion"])
    }

    @Test(arguments: [
        ("plano ext:pdf", ["plano"], ["pdf"]),
        ("plano .pdf", ["plano"], ["pdf"]),
        ("plano .PDF", ["plano"], ["pdf"]),
        ("ext:dwg ext:pdf plano", ["plano"], ["dwg", "pdf"]),
        ("ext:pdf,docx informe", ["informe"], ["pdf", "docx"]),
        ("ext:.pdf", [], ["pdf"]),
        (".pdf", [], ["pdf"]),
        ("ext:pdf .pdf", [], ["pdf"]),
        ("final.pdf", ["final.pdf"], []),
        (".", ["."], []),
        ("..", [".."], []),
        (".hidden-file", [".hidden-file"], []),
        ("plano ext:", ["plano"], []),
    ])
    func recognizesFileTypes(input: String, terms: [String], extensions: [String]) {
        let query = Query.parse(input)
        #expect(query.terms == terms)
        #expect(query.extensions == extensions)
    }

    @Test func fileTypesAreNotPartOfTheExactNameText() {
        #expect(Query.parse("Informe .docx").text == "informe")
    }

    @Test func aFileTypeAloneIsASearch() {
        #expect(!Query.parse(".pdf").isEmpty)
    }
}
