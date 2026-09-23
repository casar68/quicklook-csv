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

    @Test func quotedFieldMayContainCommaLiterally() throws {
        let table = try parseAll("\"a,b\",c\n")
        #expect(table.rows[0].value(forColumnKey: "col_0") == "a,b")
        #expect(table.rows[0].value(forColumnKey: "col_1") == "c")
    }

    @Test func quotedFieldMayContainEmbeddedNewline() throws {
        let table = try parseAll("\"a\nb\",c\n")
        #expect(table.rows.count == 1)
        #expect(table.rows[0].value(forColumnKey: "col_0") == "a\nb")
        #expect(table.rows[0].value(forColumnKey: "col_1") == "c")
    }

    @Test func doubledQuoteInsideQuotedFieldIsALiteralQuote() throws {
        let table = try parseAll("\"say \"\"hi\"\"\"\n")
        #expect(table.rows[0].value(forColumnKey: "col_0") == "say \"hi\"")
    }

    @Test func crlfLineEndingIsTreatedAsOneRowTerminator() throws {
        let table = try parseAll("a,b\r\n1,2\r\n")
        #expect(table.rows.count == 2)
        #expect(table.rows[1].value(forColumnKey: "col_1") == "2")
    }

    @Test func autoDetectsSemicolonSeparator() throws {
        let table = try parseAll("a;b;c\n1;2;3\n")
        #expect(table.columnKeys.count == 3)
        #expect(table.rows[0].value(forColumnKey: "col_1") == "b")
    }

    @Test func autoDetectsTabSeparator() throws {
        let table = try parseAll("a\tb\n1\t2\n")
        #expect(table.rows[0].value(forColumnKey: "col_1") == "b")
    }

    @Test func defaultsToCommaWhenNoOtherSeparatorWins() throws {
        let table = try parseAll("a,b,c\n")
        #expect(table.columnKeys.count == 3)
    }

    @Test func separatorDetectionIgnoresDelimitersInsideQuotedFields() throws {
        // The real separator is tab (2 occurrences outside quotes). A
        // quote-unaware count would see 8 commas (4 per row, all inside a
        // quoted field) beat 2 tabs and wrongly pick comma.
        let table = try parseAll("\"a,b,c,d,e\"\tf\n\"1,2,3,4,5\"\t6\n")
        #expect(table.rows.count == 2)
        #expect(table.rows[0].value(forColumnKey: "col_0") == "a,b,c,d,e")
        #expect(table.rows[0].value(forColumnKey: "col_1") == "f")
        #expect(table.rows[1].value(forColumnKey: "col_1") == "6")
    }

    @Test func columnsBeyondMaxColumnsAreDroppedButRowParsingContinues() throws {
        var config = CSVStreamParser.Configuration.preview
        config.maxColumns = 2
        let table = try parseAll("a,b,c,d\n1,2,3,4\n", configuration: config)
        #expect(table.columnKeys == ["col_0", "col_1"])
        #expect(table.columnsTruncated == true)
        #expect(table.rows.count == 2)
        #expect(table.rows[1].value(forColumnKey: "col_1") == "2")
    }

    @Test func cellExceedingMaxByteSizeThrowsCellTooLarge() throws {
        var config = CSVStreamParser.Configuration.preview
        config.maxCellByteSize = 8
        let parser = CSVStreamParser(configuration: config)
        _ = try parser.consume(Array("\"123456789".utf8)) // unterminated quote, 9 bytes of content
        #expect(throws: CSVStreamParser.ParseError.cellTooLarge) {
            try parser.finish()
        }
    }

    @Test func unterminatedQuoteAcrossManyChunksStopsAtCellCapInsteadOfReadingToEOF() throws {
        var config = CSVStreamParser.Configuration.preview
        config.maxCellByteSize = 100
        let parser = CSVStreamParser(configuration: config)
        var stoppedEarly = false
        // Simulate an unterminated quote followed by megabytes of data: feed
        // 1 KB chunks and confirm the parser signals "stop" long before we'd
        // have to feed the whole (simulated) file.
        let openingChunk = Array("\"".utf8)
        _ = try parser.consume(openingChunk)
        for _ in 0..<1000 {
            let chunk = Array(repeating: UInt8(ascii: "x"), count: 1024)
            if try parser.consume(chunk) {
                stoppedEarly = true
                break
            }
        }
        #expect(stoppedEarly == true)
    }
}
