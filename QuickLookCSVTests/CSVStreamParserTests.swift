import Testing
import Foundation

struct CSVStreamParserTests {
    func parseAll(_ string: String, configuration: CSVStreamParser.Configuration = .preview) throws -> ParsedCSVTable {
        let parser = CSVStreamParser(configuration: configuration)
        _ = try parser.consume(Array(string.utf8))
        return try parser.finish()
    }

    @Test func parsesSimpleCommaSeparatedRows() throws {
        let table = try parseAll("a,b,c\n1,2,3\n")
        #expect(table.columnKeys == ["col_0", "col_1", "col_2"])
        #expect(table.rows.count == 2)
        #expect(table.rows[0].value(forColumnKey: "col_0") == "a")
        #expect(table.rows[1].value(forColumnKey: "col_2") == "3")
    }

    @Test func parsesFileWithoutTrailingNewline() throws {
        let table = try parseAll("a,b\n1,2")
        #expect(table.rows.count == 2)
        #expect(table.rows[1].value(forColumnKey: "col_1") == "2")
    }

    @Test func emptyFileThrows() throws {
        let parser = CSVStreamParser(configuration: .preview)
        _ = try parser.consume([])
        #expect(throws: CSVStreamParser.ParseError.emptyFile) {
            try parser.finish()
        }
    }

    @Test func maxRowsCapKeepsExactlyMaxRowsRows() throws {
        var config = CSVStreamParser.Configuration.preview
        config.maxRows = 2
        let table = try parseAll("1\n2\n3\n4\n", configuration: config)
        #expect(table.rows.count == 2)
        #expect(table.rowsTruncated == true)
        #expect(table.rows[0].value(forColumnKey: "col_0") == "1")
        #expect(table.rows[1].value(forColumnKey: "col_0") == "2")
    }

    @Test func exactlyMaxRowsRowsIsNotFlaggedAsTruncated() throws {
        var config = CSVStreamParser.Configuration.preview
        config.maxRows = 2
        let table = try parseAll("1\n2\n", configuration: config)
        #expect(table.rows.count == 2)
        #expect(table.rowsTruncated == false)
    }

    @Test func consumeAcrossMultipleChunksProducesSameResultAsOneShot() throws {
        let parser = CSVStreamParser(configuration: .preview)
        let bytes = Array("a,b\n1,2\n".utf8)
        _ = try parser.consume(Array(bytes[0..<3]))
        _ = try parser.consume(Array(bytes[3...]))
        let table = try parser.finish()
        #expect(table.rows.count == 2)
        #expect(table.rows[1].value(forColumnKey: "col_1") == "2")
    }
}
