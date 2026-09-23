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

    private func utf16LEBytes(_ string: String, bom: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = bom ? [0xFF, 0xFE] : []
        for scalar in string.utf16 {
            bytes.append(UInt8(scalar & 0xFF))
            bytes.append(UInt8(scalar >> 8))
        }
        return bytes
    }

    @Test func parsesUTF16LEFileWithBOM() throws {
        let parser = CSVStreamParser(configuration: .preview)
        _ = try parser.consume(utf16LEBytes("a,b\n1,2\n"))
        let table = try parser.finish()
        #expect(table.rows.count == 2)
        #expect(table.rows[1].value(forColumnKey: "col_1") == "2")
    }

    @Test func utf16CharacterWithCommaByteValueIsNotMistakenForADelimiter() throws {
        // U+222C (∬) encodes in UTF-16LE as bytes [0x2C, 0x22] — the first
        // byte equals the ASCII comma. A byte-level scan would misparse
        // this; a unit-level scan must not.
        let parser = CSVStreamParser(configuration: .preview)
        let content = "a\u{222C}b,c\n" // "a∬b,c\n"
        _ = try parser.consume(utf16LEBytes(content))
        let table = try parser.finish()
        #expect(table.rows.count == 1)
        #expect(table.rows[0].value(forColumnKey: "col_0") == "a\u{222C}b")
        #expect(table.rows[0].value(forColumnKey: "col_1") == "c")
    }

    @Test func utf16UnitSplitAcrossChunkBoundaryIsHandledCorrectly() throws {
        // With the default `.preview` config (detectionPrefixByteSize:
        // 65_536), this whole 18-byte input would be fully absorbed by
        // prefix buffering inside a single `feed()` call before
        // `consumeUnits` ever ran on it in two separate pieces -- so a split
        // at any offset would never actually exercise the `leftoverByte`
        // carry between two `consume()` calls. To exercise it for real, use
        // a tiny `detectionPrefixByteSize` so prefix detection completes
        // partway through the FIRST `consume()` call, and place the split
        // point one byte after that -- landing on the first byte of a 2-byte
        // unit ("b"'s low byte) so its second byte only arrives in the
        // SECOND `consume()` call and must be carried via `leftoverByte`.
        var config = CSVStreamParser.Configuration.preview
        config.detectionPrefixByteSize = 4 // "a," (2 units) -- completes prefix detection mid-first-call
        let parser = CSVStreamParser(configuration: config)
        let bytes = utf16LEBytes("a,b\n1,2\n")
        // bytes = BOM(2) + "a"(2) + ","(2) + "b"(2) + "\n"(2) + "1"(2) + ","(2) + "2"(2) + "\n"(2) = 18 bytes.
        // splitPoint 7 = BOM(2) + "a,"(4) + the first byte of "b"'s 2-byte unit (1).
        let splitPoint = 7
        _ = try parser.consume(Array(bytes[0..<splitPoint]))
        _ = try parser.consume(Array(bytes[splitPoint...]))
        let table = try parser.finish()
        #expect(table.rows.count == 2)
        #expect(table.rows[0].value(forColumnKey: "col_1") == "b")
        #expect(table.rows[1].value(forColumnKey: "col_1") == "2")
    }

    @Test func cellDecodeFallsBackToISOLatin1BeyondDetectionPrefix() throws {
        var config = CSVStreamParser.Configuration.preview
        config.detectionPrefixByteSize = 4 // force the prefix window to be tiny
        let parser = CSVStreamParser(configuration: config)
        // Prefix ("a,b\n") is pure ASCII so UTF-8 is chosen; the later byte
        // 0xE9 alone is not valid UTF-8 but is a valid ISO-8859-1 "é".
        var bytes = Array("a,b\n".utf8)
        bytes.append(contentsOf: [0xE9, 0x0A]) // "é\n" in ISO-8859-1
        _ = try parser.consume(bytes)
        let table = try parser.finish()
        #expect(table.rows.count == 2)
        #expect(table.rows[1].value(forColumnKey: "col_0") == "é")
    }

    @Test func utf16DecodeFailureDoesNotFallBackToISOLatin1() throws {
        // The ISO-8859-1 fallback must be confined to the single-byte
        // stride. Feeding it 2-byte UTF-16 cell bytes would produce
        // mojibake (every byte reinterpreted as its own Latin-1 character,
        // including embedded NUL bytes) instead of an empty/best-effort
        // result.
        let parser = CSVStreamParser(configuration: .preview)
        var bytes: [UInt8] = [0xFF, 0xFE]       // UTF-16LE BOM
        bytes.append(contentsOf: [0x61, 0x00])  // "a"
        bytes.append(contentsOf: [0x2C, 0x00])  // ","
        bytes.append(contentsOf: [0x00, 0xDC])  // lone low surrogate U+DC00 — invalid UTF-16 on its own
        bytes.append(contentsOf: [0x0A, 0x00])  // "\n"
        _ = try parser.consume(bytes)
        let table = try parser.finish()
        #expect(table.rows[0].value(forColumnKey: "col_1").contains("\0") == false)
    }

    @Test func singleByteTotalInputIsNotSilentlyDropped() throws {
        // A stream of only 0-1 bytes never gives `determineStride` the 2
        // bytes it needs to conclusively rule a BOM in or out, so those
        // bytes get stuck in `bomSniffBuffer` and never reach
        // `feed`/`prefixBuffer`. Without a flush in `finish()`, this would
        // silently produce an empty table (0 rows) instead of surfacing the
        // file's real (if minimal) content, even though `sawAnyByte` is
        // `true` so `.emptyFile` isn't thrown either.
        //
        // Tracing the actual parse of a lone "," with no trailing newline:
        // `finish()` flushes the single byte as single-byte-stride data,
        // prefix detection sees one comma (picks comma as the separator),
        // `consumeUnits` processes it as a separator hit (finalizing an
        // empty cell before it), and then `finish()`'s existing
        // `cellsSeenInCurrentRow > 0` check commits the row, finalizing a
        // second empty cell after it -- one row, two empty cells.
        let table = try parseAll(",")
        #expect(table.rows.count == 1)
        #expect(table.rows[0].value(forColumnKey: "col_0") == "")
        #expect(table.rows[0].value(forColumnKey: "col_1") == "")
    }
}
