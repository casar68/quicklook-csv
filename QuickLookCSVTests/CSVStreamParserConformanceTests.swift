import Testing
import Foundation

struct CSVStreamParserConformanceTests {
    func fixtureURL(_ name: String) -> URL {
        Bundle(for: BundleMarker.self).url(forResource: name, withExtension: nil)!
    }

    @Test func parsesFixtureFileFromDisk() throws {
        let table = try CSVStreamParser.parse(fileAt: fixtureURL("test.csv"), configuration: .preview)
        #expect(table.rows.count > 0)
    }

    @Test(arguments: ["test.csv", "testHeight.csv", "testWidth.csv", "testMini.csv"])
    func matchesLegacyCSVDocumentOutput(fixtureName: String) throws {
        let url = fixtureURL(fixtureName)

        let newTable = try CSVStreamParser.parse(fileAt: url, configuration: .preview)

        let legacyDoc = CSVDocument()
        legacyDoc.autoDetectSeparator = true
        let fileString = try String(contentsOf: url, encoding: .utf8)
        _ = legacyDoc.numRows(fromCSVString: fileString, maxRows: 500, error: nil)

        #expect(newTable.columnKeys.count == legacyDoc.columnKeys.count)
        #expect(newTable.rows.count == legacyDoc.rows.count)
        for (index, legacyRowAny) in legacyDoc.rows.enumerated() {
            let legacyRow = legacyRowAny as! CSVRowObject
            for key in newTable.columnKeys {
                #expect(newTable.rows[index].value(forColumnKey: key) == (legacyRow.column(forKey: key) ?? ""))
            }
        }
    }
}

private final class BundleMarker {}
