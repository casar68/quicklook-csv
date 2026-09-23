# QuickLook CSV — Preview/Thumbnail Extension Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the deprecated `.qlgenerator` CFPlugIn with a Preview Extension and a Thumbnail Extension hosted in a minimal new app, without touching the legacy target, and with a new memory-safe streaming CSV parser written in Swift.

**Architecture:** Three new Xcode targets (`QuickLookCSVApp` host app, `QuickLookCSVPreview`, `QuickLookCSVThumbnail`) added to the existing project alongside the untouched legacy `QuickLookCSV` target. A new, independent Swift parser (`CSVStreamParser`) reads files incrementally in bounded chunks and is exclusive to the two new extension targets — it does not touch or depend on the legacy `CSVDocument`/`CSVRowObject` Objective-C classes. The Preview Extension renders a native SwiftUI `Table`; the Thumbnail Extension reuses the existing Core Graphics drawing approach adapted to the new parser's output.

**Tech Stack:** Swift, SwiftUI (`Table`, `NSHostingController`), QuickLookUI (`QLPreviewingController`, `QLPreviewReply`), QuickLookThumbnailing (`QLThumbnailProvider`, `QLThumbnailReply`), Swift Testing framework.

**Spec:** `docs/superpowers/specs/2026-09-23-quicklook-extension-migration-design.md`

## Global Constraints

- Deployment target for all three new targets: macOS 13.0.
- New code (host app, both extensions) is Swift. `CSVDocument.h/.m` and `CSVRowObject.h/.m` are never modified and never added to the new targets — they stay exclusive to the legacy `QuickLookCSV` target.
- The legacy `QuickLookCSV` target is not modified in this plan (no files, no build settings).
- `CSVStreamParser` and `ParsedCSVTable`/`CSVRow` are new Swift files, added as members of `QuickLookCSVPreview` and `QuickLookCSVThumbnail` only.
- Default limits: `maxRows` = 500 for preview / 18 for thumbnail (matching legacy `MAX_ROWS`/`NUM_ROWS`), `maxColumns` = 50, `maxCellByteSize` = 1,000,000 bytes, `detectionPrefixByteSize` = `chunkByteSize` = 65,536 bytes.
- All file reads in the new targets wrap `startAccessingSecurityScopedResource()`/`stopAccessingSecurityScopedResource()` defensively.
- Tests use the **Testing** framework (`import Testing`, `@Test`, `#expect`), not XCTest.
- No new user-facing behavior beyond parity with the legacy preview/thumbnail, except native column sorting in `Table` (a free side effect of the SwiftUI component, not something to build).

---

## Task 1: New test target and `ParsedCSVTable` data model

**Files:**
- Create test target `QuickLookCSVTests` (Xcode project change, via `XcodeNewTarget`)
- Create: `QuickLookCSVTests/ParsedCSVTableTests.swift`
- Create: `Shared/ParsedCSVTable.swift` (added as a member of `QuickLookCSVTests` for now; will also be added to `QuickLookCSVPreview`/`QuickLookCSVThumbnail` in Task 7/9)

**Interfaces:**
- Produces: `CSVRow` (`Identifiable`, `Equatable`, `id: Int`, `cells: [String: String]`, `func value(forColumnKey key: String) -> String`), `ParsedCSVTable` (`Equatable`, `columnKeys: [String]`, `rows: [CSVRow]`, `rowsTruncated: Bool`, `columnsTruncated: Bool`).

- [ ] **Step 1: Create the test target**

Use `XcodeNewTarget` with:
```
templateIdentifier: "com.apple.dt.unit.multiPlatform.unitTestBundle"
productName: "QuickLookCSVTests"
options: { "languageChoice": "Swift", "testingSystem": "Swift Testing" }
```

- [ ] **Step 2: Write the failing test for `CSVRow`/`ParsedCSVTable`**

Create `QuickLookCSVTests/ParsedCSVTableTests.swift`:

```swift
import Testing

struct ParsedCSVTableTests {
    @Test func rowValueForColumnKeyReturnsCellContent() {
        let row = CSVRow(id: 0, cells: ["col_0": "hello", "col_1": "world"])
        #expect(row.value(forColumnKey: "col_0") == "hello")
        #expect(row.value(forColumnKey: "col_1") == "world")
    }

    @Test func rowValueForMissingColumnKeyReturnsEmptyString() {
        let row = CSVRow(id: 0, cells: ["col_0": "hello"])
        #expect(row.value(forColumnKey: "col_5") == "")
    }

    @Test func parsedCSVTableStoresColumnsAndRows() {
        let table = ParsedCSVTable(
            columnKeys: ["col_0", "col_1"],
            rows: [CSVRow(id: 0, cells: ["col_0": "a", "col_1": "b"])],
            rowsTruncated: false,
            columnsTruncated: false
        )
        #expect(table.columnKeys == ["col_0", "col_1"])
        #expect(table.rows.count == 1)
        #expect(table.rowsTruncated == false)
        #expect(table.columnsTruncated == false)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Build the `QuickLookCSVTests` target. Expected: compile error — `CSVRow`/`ParsedCSVTable` not defined.

- [ ] **Step 4: Implement the data model**

Create `Shared/ParsedCSVTable.swift` (add as a member of `QuickLookCSVTests` target):

```swift
struct CSVRow: Identifiable, Equatable {
    let id: Int
    let cells: [String: String]

    func value(forColumnKey key: String) -> String {
        cells[key] ?? ""
    }
}

struct ParsedCSVTable: Equatable {
    let columnKeys: [String]
    let rows: [CSVRow]
    let rowsTruncated: Bool
    let columnsTruncated: Bool
    var isTabSeparated: Bool = false
    var fileSizeBytes: Int64 = 0
}
```

`isTabSeparated` (used for the thumbnail badge in Task 9) and `fileSizeBytes` (used for the file-size display and the sandbox-access fix in Task 6/8) have default values, so the synthesized memberwise initializer keeps both parameters optional (Swift default-value-in-memberwise-init behavior) — the Step 2 test above compiles unchanged, and `CSVStreamParser.finish()` in Tasks 2–5 can keep constructing `ParsedCSVTable` without naming them until Task 5/6 need to set them explicitly.

- [ ] **Step 5: Run tests to verify they pass**

Build and run the `QuickLookCSVTests` target (`RunAllTests` or `RunSomeTests` scoped to `QuickLookCSVTests`). Expected: all 3 tests PASS.

- [ ] **Step 6: Commit**

```bash
git add QuickLookCSVTests QuickLookCSV.xcodeproj/project.pbxproj Shared/ParsedCSVTable.swift
git commit -m "Add QuickLookCSVTests target and ParsedCSVTable data model"
```

---

## Task 2: `CSVStreamParser` core — unquoted single-byte parsing, `maxRows` cap

**Files:**
- Create: `Shared/CSVStreamParser.swift` (member of `QuickLookCSVTests`)
- Create: `QuickLookCSVTests/CSVStreamParserTests.swift`

**Interfaces:**
- Consumes: `CSVRow`, `ParsedCSVTable` (Task 1).
- Produces: `CSVStreamParser` (`final class`), `CSVStreamParser.Configuration` (`maxRows: Int`, `maxColumns: Int`, `maxCellByteSize: Int`, `detectionPrefixByteSize: Int`, `chunkByteSize: Int`, static `.preview`/`.thumbnail`), `CSVStreamParser.ParseError` (`.emptyFile`, `.cellTooLarge`, `.unreadableFile`), `init(configuration:)`, `func consume(_ chunk: [UInt8]) throws -> Bool`, `func finish() throws -> ParsedCSVTable`.

This task builds the parser with **only** comma as separator and **no** quote handling yet (added in Task 3) — deliberately staged so the row/column bookkeeping is proven correct before adding quoting complexity.

- [ ] **Step 1: Write the failing tests**

Create `QuickLookCSVTests/CSVStreamParserTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Build/run `QuickLookCSVTests`. Expected: compile error — `CSVStreamParser` not defined.

- [ ] **Step 3: Implement `CSVStreamParser` (comma-only, no quoting)**

Create `Shared/CSVStreamParser.swift`:

```swift
import Foundation

final class CSVStreamParser {
    enum ParseError: Error, Equatable {
        case emptyFile
        case cellTooLarge
        case unreadableFile
    }

    struct Configuration {
        var maxRows: Int
        var maxColumns: Int
        var maxCellByteSize: Int
        var detectionPrefixByteSize: Int
        var chunkByteSize: Int

        static let preview = Configuration(
            maxRows: 500, maxColumns: 50, maxCellByteSize: 1_000_000,
            detectionPrefixByteSize: 65_536, chunkByteSize: 65_536
        )
        static let thumbnail = Configuration(
            maxRows: 18, maxColumns: 50, maxCellByteSize: 1_000_000,
            detectionPrefixByteSize: 65_536, chunkByteSize: 65_536
        )
    }

    private enum Unit {
        static let comma: UInt16 = 0x2C
        static let lf: UInt16 = 0x0A
        static let cr: UInt16 = 0x0D
    }

    private let configuration: Configuration

    private var cellBytes: [UInt8] = []
    private var currentRowValues: [String] = []
    private var cellsSeenInCurrentRow = 0
    private var columnCount = 0
    private var rows: [CSVRow] = []
    private var rowsTruncated = false
    private var columnsTruncated = false
    private var justSawCR = false
    private var sawAnyByte = false
    private var finished = false
    private var pendingError: ParseError?

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func consume(_ chunk: [UInt8]) throws -> Bool {
        guard !finished else { return true }
        guard !chunk.isEmpty else { return finished }
        sawAnyByte = true
        try feed(chunk)
        return finished
    }

    func finish() throws -> ParsedCSVTable {
        if pendingError == nil && !finished && cellsSeenInCurrentRow > 0 {
            commitRow()
        }
        if let error = pendingError {
            throw error
        }
        guard sawAnyByte else {
            throw ParseError.emptyFile
        }
        let keys = (0..<columnCount).map { "col_\($0)" }
        return ParsedCSVTable(
            columnKeys: keys, rows: rows,
            rowsTruncated: rowsTruncated, columnsTruncated: columnsTruncated
        )
    }

    private func feed(_ bytes: [UInt8]) throws {
        for byte in bytes {
            process(unit: UInt16(byte))
            if finished { return }
        }
        if let error = pendingError {
            finished = true
            throw error
        }
    }

    private func process(unit: UInt16) {
        if unit == Unit.comma {
            justSawCR = false
            finalizeCurrentCell()
        } else if unit == Unit.cr {
            justSawCR = true
            commitRow()
        } else if unit == Unit.lf {
            if justSawCR {
                justSawCR = false
            } else {
                commitRow()
            }
        } else {
            justSawCR = false
            appendToCell(unit: unit)
        }
    }

    private func appendToCell(unit: UInt16) {
        guard cellsSeenInCurrentRow < configuration.maxColumns else { return }
        cellBytes.append(UInt8(unit))
        if cellBytes.count > configuration.maxCellByteSize {
            pendingError = .cellTooLarge
            finished = true
        }
    }

    private func finalizeCurrentCell() {
        if cellsSeenInCurrentRow < configuration.maxColumns {
            currentRowValues.append(String(decoding: cellBytes, as: UTF8.self))
        }
        cellBytes.removeAll(keepingCapacity: true)
        cellsSeenInCurrentRow += 1
    }

    private func commitRow() {
        finalizeCurrentCell()

        if cellsSeenInCurrentRow > configuration.maxColumns {
            columnsTruncated = true
        }
        columnCount = max(columnCount, min(cellsSeenInCurrentRow, configuration.maxColumns))

        if rows.count >= configuration.maxRows {
            rowsTruncated = true
            finished = true
        } else {
            var cells: [String: String] = [:]
            for (index, value) in currentRowValues.enumerated() {
                cells["col_\(index)"] = value
            }
            rows.append(CSVRow(id: rows.count, cells: cells))
        }

        currentRowValues.removeAll(keepingCapacity: true)
        cellsSeenInCurrentRow = 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Build/run `QuickLookCSVTests`. Expected: all tests in `CSVStreamParserTests` PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/CSVStreamParser.swift QuickLookCSVTests/CSVStreamParserTests.swift
git commit -m "Add CSVStreamParser core: unquoted comma-separated parsing with maxRows cap"
```

---

## Task 3: Quoting support (escaped `""`, embedded newlines, CRLF)

**Files:**
- Modify: `Shared/CSVStreamParser.swift`
- Modify: `QuickLookCSVTests/CSVStreamParserTests.swift`

**Interfaces:** No public signature changes — internal state machine only.

- [ ] **Step 1: Write the failing tests**

Append to `CSVStreamParserTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: `quotedFieldMayContainCommaLiterally` and the others FAIL (quotes currently treated as plain content, not toggling any mode).

- [ ] **Step 3: Implement quote handling**

In `Shared/CSVStreamParser.swift`, add `quote` to `Unit`, add `insideQuotes`/`pendingCloseQuote` state, and rewrite `process(unit:)`:

```swift
    private enum Unit {
        static let comma: UInt16 = 0x2C
        static let lf: UInt16 = 0x0A
        static let cr: UInt16 = 0x0D
        static let quote: UInt16 = 0x22
    }
```

```swift
    private var insideQuotes = false
    private var pendingCloseQuote = false
```

```swift
    private func process(unit: UInt16) {
        if pendingCloseQuote {
            pendingCloseQuote = false
            if unit == Unit.quote {
                appendToCell(unit: unit)
                insideQuotes = true
                return
            }
            // Field really closed; insideQuotes is already false. Fall
            // through to process this unit normally below.
        }

        if unit == Unit.quote {
            justSawCR = false
            if insideQuotes {
                pendingCloseQuote = true
                insideQuotes = false
            } else {
                insideQuotes = true
            }
        } else if unit == Unit.comma && !insideQuotes {
            justSawCR = false
            finalizeCurrentCell()
        } else if unit == Unit.cr && !insideQuotes {
            justSawCR = true
            commitRow()
        } else if unit == Unit.lf && !insideQuotes {
            if justSawCR {
                justSawCR = false
            } else {
                commitRow()
            }
        } else {
            justSawCR = false
            appendToCell(unit: unit)
        }
    }
```

Note the opening quote itself and the closing quote are never appended to `cellBytes` (they're consumed as delimiters, matching legacy behavior of `NSScanner`), only content and doubled-quote escapes are appended.

- [ ] **Step 4: Run tests to verify they pass**

Expected: all tests in `CSVStreamParserTests` PASS, including the Task 2 tests (no regression).

- [ ] **Step 5: Commit**

```bash
git add Shared/CSVStreamParser.swift QuickLookCSVTests/CSVStreamParserTests.swift
git commit -m "Add quote handling to CSVStreamParser: escaping, embedded newlines, CRLF"
```

---

## Task 4: Separator auto-detection, `maxColumns` cap, per-cell memory cap

**Files:**
- Modify: `Shared/CSVStreamParser.swift`
- Modify: `QuickLookCSVTests/CSVStreamParserTests.swift`

**Interfaces:** No public signature changes.

- [ ] **Step 1: Write the failing tests**

Append to `CSVStreamParserTests`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: separator-detection and cap tests FAIL (parser currently hardcodes comma and has no `maxCellByteSize`/`maxColumns` enforcement wired to a real error).

- [ ] **Step 3: Implement separator auto-detection and the two caps**

`maxCellByteSize` enforcement already exists from Task 2's `appendToCell` — Step 1's new test `cellExceedingMaxByteSizeThrowsCellTooLarge` should already pass; if it doesn't, check that `consume`/`finish` propagate `pendingError` (it should, per Task 2's `feed`). Add separator auto-detection in `Shared/CSVStreamParser.swift`:

```swift
    private enum SeparatorCandidate: CaseIterable {
        case comma, semicolon, tab, pipe

        var codeUnit: UInt16 {
            switch self {
            case .comma: return 0x2C
            case .semicolon: return 0x3B
            case .tab: return 0x09
            case .pipe: return 0x7C
            }
        }
    }
```

Replace the hardcoded `Unit.comma` separator check in `process(unit:)` with a `separatorUnit` property, and add prefix buffering before parsing starts:

```swift
    private var separatorUnit: UInt16 = SeparatorCandidate.comma.codeUnit
    private var prefixBuffer: [UInt8] = []
    private var prefixComplete = false
```

```swift
    private func process(unit: UInt16) {
        if pendingCloseQuote {
            pendingCloseQuote = false
            if unit == Unit.quote {
                appendToCell(unit: unit)
                insideQuotes = true
                return
            }
        }

        if unit == Unit.quote {
            justSawCR = false
            if insideQuotes {
                pendingCloseQuote = true
                insideQuotes = false
            } else {
                insideQuotes = true
            }
        } else if unit == separatorUnit && !insideQuotes {
            justSawCR = false
            finalizeCurrentCell()
        } else if unit == Unit.cr && !insideQuotes {
            justSawCR = true
            commitRow()
        } else if unit == Unit.lf && !insideQuotes {
            if justSawCR {
                justSawCR = false
            } else {
                commitRow()
            }
        } else {
            justSawCR = false
            appendToCell(unit: unit)
        }
    }
```

Update `feed(_:)` to buffer the detection prefix before running `process` on any byte, then flush once the prefix is complete (or once EOF is reached with a shorter file, handled from `finish()`):

```swift
    private func feed(_ bytes: [UInt8]) throws {
        var remaining = bytes[...]
        if !prefixComplete {
            let room = configuration.detectionPrefixByteSize - prefixBuffer.count
            let toBuffer = remaining.prefix(room)
            prefixBuffer.append(contentsOf: toBuffer)
            remaining = remaining.dropFirst(toBuffer.count)
            if prefixBuffer.count >= configuration.detectionPrefixByteSize {
                finalizePrefixDetection()
            } else {
                return
            }
        }
        for byte in remaining {
            process(unit: UInt16(byte))
            if finished { return }
        }
        if let error = pendingError {
            finished = true
            throw error
        }
    }

    private func finalizePrefixDetection() {
        separatorUnit = detectSeparator(in: prefixBuffer)
        isTabSeparated = (separatorUnit == SeparatorCandidate.tab.codeUnit)
        prefixComplete = true
        let buffered = prefixBuffer
        prefixBuffer = []
        for byte in buffered {
            process(unit: UInt16(byte))
            if finished { return }
        }
    }

    /// Counts each candidate separator only outside quoted spans. A raw,
    /// quote-unaware count would let a quoted field's internal punctuation
    /// (e.g. a long comma-separated sentence quoted in an otherwise
    /// tab-separated file) outvote the real separator. This uses a plain
    /// quote-toggle (not the full "" escape handling `process` uses) —
    /// good enough for a detection heuristic; the real parse in `process`
    /// is unaffected and stays fully correct.
    private func detectSeparator(in bytes: [UInt8]) -> UInt16 {
        var counts: [UInt16: Int] = [:]
        for candidate in SeparatorCandidate.allCases {
            counts[candidate.codeUnit] = 0
        }

        var insideQuotesForDetection = false
        for byte in bytes {
            let u = UInt16(byte)
            if u == Unit.quote {
                insideQuotesForDetection.toggle()
            } else if !insideQuotesForDetection, counts[u] != nil {
                counts[u, default: 0] += 1
            }
        }

        var best = SeparatorCandidate.comma.codeUnit
        var bestCount = counts[best] ?? 0
        for candidate in SeparatorCandidate.allCases where candidate != .comma {
            let candidateCount = counts[candidate.codeUnit] ?? 0
            if candidateCount > bestCount {
                best = candidate.codeUnit
                bestCount = candidateCount
            }
        }
        return best
    }
```

Add the `isTabSeparated` property alongside the other detection state:

```swift
    private var isTabSeparated = false
```

And `finish()` must flush a not-yet-complete prefix buffer (short file) before committing the trailing row, and include `isTabSeparated` in the returned table:

```swift
    func finish() throws -> ParsedCSVTable {
        if pendingError == nil && !finished {
            if !prefixComplete {
                finalizePrefixDetection()
            }
            if cellsSeenInCurrentRow > 0 {
                commitRow()
            }
        }
        if let error = pendingError {
            throw error
        }
        guard sawAnyByte else {
            throw ParseError.emptyFile
        }
        let keys = (0..<columnCount).map { "col_\($0)" }
        return ParsedCSVTable(
            columnKeys: keys, rows: rows,
            rowsTruncated: rowsTruncated, columnsTruncated: columnsTruncated,
            isTabSeparated: isTabSeparated
        )
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: all tests in `CSVStreamParserTests` PASS, including Tasks 2 and 3 (no regression).

- [ ] **Step 5: Commit**

```bash
git add Shared/CSVStreamParser.swift QuickLookCSVTests/CSVStreamParserTests.swift
git commit -m "Add separator auto-detection, maxColumns cap, and per-cell memory cap to CSVStreamParser"
```

---

## Task 5: UTF-16 BOM/stride detection and per-cell ISO-8859-1 fallback decode

**Files:**
- Modify: `Shared/CSVStreamParser.swift`
- Modify: `QuickLookCSVTests/CSVStreamParserTests.swift`

**Interfaces:** No public signature changes.

This is the fix for the reviewed defect: a byte-per-byte scan is unsafe for UTF-16, where a non-ASCII character's code unit can coincidentally contain the byte value of a delimiter. From this task on, the parser scans in **units** (1 or 2 bytes, decided once from the leading BOM) instead of raw bytes.

- [ ] **Step 1: Write the failing tests**

Append to `CSVStreamParserTests`:

```swift
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
        let parser = CSVStreamParser(configuration: .preview)
        let bytes = utf16LEBytes("a,b\n1,2\n")
        // Split in the middle of a 2-byte unit (odd offset) to exercise the
        // leftover-byte carry logic.
        let splitPoint = 5
        _ = try parser.consume(Array(bytes[0..<splitPoint]))
        _ = try parser.consume(Array(bytes[splitPoint...]))
        let table = try parser.finish()
        #expect(table.rows.count == 2)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: UTF-16 tests FAIL (parser currently only understands single bytes) and the ISO-8859-1 fallback test likely already passes trivially or fails depending on `String(decoding:as: UTF8.self)`'s lossy substitution behavior — verify it fails as an incorrect value (mojibake/replacement character) rather than the expected `"é"`.

- [ ] **Step 3: Implement stride dispatch and per-cell fallback decode**

Rewrite `Shared/CSVStreamParser.swift`'s byte-consumption path to operate on **units** instead of raw bytes. Replace `feed(_:)`, `process(unit:)`'s caller, and `appendToCell`/`finalizeCurrentCell`/`detectSeparator` to use a stride-aware unit reader. Full updated file:

```swift
import Foundation

final class CSVStreamParser {
    enum ParseError: Error, Equatable {
        case emptyFile
        case cellTooLarge
        case unreadableFile
    }

    struct Configuration {
        var maxRows: Int
        var maxColumns: Int
        var maxCellByteSize: Int
        var detectionPrefixByteSize: Int
        var chunkByteSize: Int

        static let preview = Configuration(
            maxRows: 500, maxColumns: 50, maxCellByteSize: 1_000_000,
            detectionPrefixByteSize: 65_536, chunkByteSize: 65_536
        )
        static let thumbnail = Configuration(
            maxRows: 18, maxColumns: 50, maxCellByteSize: 1_000_000,
            detectionPrefixByteSize: 65_536, chunkByteSize: 65_536
        )
    }

    private enum Unit {
        static let comma: UInt16 = 0x2C
        static let lf: UInt16 = 0x0A
        static let cr: UInt16 = 0x0D
        static let quote: UInt16 = 0x22
    }

    private enum SeparatorCandidate: CaseIterable {
        case comma, semicolon, tab, pipe

        var codeUnit: UInt16 {
            switch self {
            case .comma: return 0x2C
            case .semicolon: return 0x3B
            case .tab: return 0x09
            case .pipe: return 0x7C
            }
        }
    }

    private enum Stride {
        case singleByte
        case utf16LittleEndian
        case utf16BigEndian
    }

    private let configuration: Configuration

    private var strideDetermined = false
    private var stride: Stride = .singleByte
    private var bomSniffBuffer: [UInt8] = []
    private var leftoverByte: UInt8?

    private var separatorUnit: UInt16 = SeparatorCandidate.comma.codeUnit
    private var prefixBuffer: [UInt8] = []
    private var prefixComplete = false

    private var insideQuotes = false
    private var pendingCloseQuote = false
    private var cellBytes: [UInt8] = []
    private var currentRowValues: [String] = []
    private var cellsSeenInCurrentRow = 0
    private var columnCount = 0
    private var rows: [CSVRow] = []
    private var rowsTruncated = false
    private var columnsTruncated = false
    private var justSawCR = false
    private var sawAnyByte = false
    private var finished = false
    private var pendingError: ParseError?
    private var isTabSeparated = false

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func consume(_ chunk: [UInt8]) throws -> Bool {
        guard !finished else { return true }
        guard !chunk.isEmpty else { return finished }
        sawAnyByte = true

        var remaining = chunk
        if !strideDetermined {
            determineStride(from: &remaining)
            guard strideDetermined else { return finished }
        } else if let leftover = leftoverByte {
            remaining = [leftover] + remaining
            leftoverByte = nil
        }
        guard !remaining.isEmpty else { return finished }

        try feed(remaining)
        return finished
    }

    func finish() throws -> ParsedCSVTable {
        if pendingError == nil && !finished {
            if !prefixComplete {
                try finalizePrefixDetection()
            }
            if cellsSeenInCurrentRow > 0 {
                commitRow()
            }
        }
        if let error = pendingError {
            throw error
        }
        guard sawAnyByte else {
            throw ParseError.emptyFile
        }
        let keys = (0..<columnCount).map { "col_\($0)" }
        return ParsedCSVTable(
            columnKeys: keys, rows: rows,
            rowsTruncated: rowsTruncated, columnsTruncated: columnsTruncated,
            isTabSeparated: isTabSeparated
        )
    }

    private func determineStride(from chunk: inout [UInt8]) {
        let needed = 2 - bomSniffBuffer.count
        if needed > 0 {
            let take = min(needed, chunk.count)
            bomSniffBuffer.append(contentsOf: chunk.prefix(take))
            chunk.removeFirst(take)
        }
        guard bomSniffBuffer.count == 2 else { return }

        if bomSniffBuffer == [0xFF, 0xFE] {
            stride = .utf16LittleEndian
        } else if bomSniffBuffer == [0xFE, 0xFF] {
            stride = .utf16BigEndian
        } else {
            stride = .singleByte
            chunk = bomSniffBuffer + chunk
        }
        strideDetermined = true
    }

    private func unitWidth() -> Int {
        stride == .singleByte ? 1 : 2
    }

    private func unit(at index: Int, in bytes: [UInt8]) -> UInt16 {
        switch stride {
        case .singleByte:
            return UInt16(bytes[index])
        case .utf16LittleEndian:
            return UInt16(bytes[index]) | (UInt16(bytes[index + 1]) << 8)
        case .utf16BigEndian:
            return (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
        }
    }

    private func feed(_ bytes: [UInt8]) throws {
        var remaining = bytes[...]
        if !prefixComplete {
            let room = configuration.detectionPrefixByteSize - prefixBuffer.count
            let toBuffer = remaining.prefix(max(room, 0))
            prefixBuffer.append(contentsOf: toBuffer)
            remaining = remaining.dropFirst(toBuffer.count)
            if prefixBuffer.count >= configuration.detectionPrefixByteSize {
                try finalizePrefixDetection()
                if finished { return }
            } else {
                return
            }
        }
        try consumeUnits(Array(remaining))
    }

    private func consumeUnits(_ bytes: [UInt8]) throws {
        let width = unitWidth()
        var index = 0
        while index < bytes.count {
            if width == 2 && index + 1 >= bytes.count {
                leftoverByte = bytes[index]
                index += 1
                break
            }
            let u = unit(at: index, in: bytes)
            let raw = Array(bytes[index..<(index + width)])
            index += width

            process(unit: u, rawBytes: raw)
            // `return`, not `break`: a mid-loop error (e.g. cellTooLarge)
            // must skip the throw below and defer to finish(), matching
            // every earlier task's contract — consume() never throws for
            // a data error, only finish() does. `break` would fall through
            // to the throw and make consume() throw immediately instead,
            // breaking existing callers (e.g. the maxCellByteSize test in
            // Task 4) that call consume() directly and expect a Bool, not
            // a thrown error, when the cap is hit mid-stream.
            if finished { return }
        }
        if let error = pendingError {
            finished = true
            throw error
        }
    }

    private func finalizePrefixDetection() throws {
        separatorUnit = detectSeparator(in: prefixBuffer)
        isTabSeparated = (separatorUnit == SeparatorCandidate.tab.codeUnit)
        prefixComplete = true
        let buffered = prefixBuffer
        prefixBuffer = []
        // Propagate with `try`, not `try?` — swallowing this would rely on
        // `pendingError` being checked incidentally by a later caller
        // instead of surfacing the error at the point it actually occurs.
        try consumeUnits(buffered)
    }

    /// Counts each candidate separator only outside quoted spans (using a
    /// plain quote-toggle, not the full "" escape handling `process` uses —
    /// sufficient for this detection heuristic). Without this, a quoted
    /// field's internal punctuation (e.g. a long comma-separated sentence
    /// quoted in an otherwise tab-separated file) could outvote the real
    /// separator.
    private func detectSeparator(in bytes: [UInt8]) -> UInt16 {
        let width = unitWidth()
        var counts: [UInt16: Int] = [:]
        for candidate in SeparatorCandidate.allCases {
            counts[candidate.codeUnit] = 0
        }

        var insideQuotesForDetection = false
        var index = 0
        while index + width <= bytes.count {
            let u = unit(at: index, in: bytes)
            if u == Unit.quote {
                insideQuotesForDetection.toggle()
            } else if !insideQuotesForDetection, counts[u] != nil {
                counts[u, default: 0] += 1
            }
            index += width
        }

        var best = SeparatorCandidate.comma.codeUnit
        var bestCount = counts[best] ?? 0
        for candidate in SeparatorCandidate.allCases where candidate != .comma {
            let candidateCount = counts[candidate.codeUnit] ?? 0
            if candidateCount > bestCount {
                best = candidate.codeUnit
                bestCount = candidateCount
            }
        }
        return best
    }

    private func process(unit: UInt16, rawBytes: [UInt8]) {
        if pendingCloseQuote {
            pendingCloseQuote = false
            if unit == Unit.quote {
                appendToCell(rawBytes)
                insideQuotes = true
                return
            }
        }

        if unit == Unit.quote {
            justSawCR = false
            if insideQuotes {
                pendingCloseQuote = true
                insideQuotes = false
            } else {
                insideQuotes = true
            }
        } else if unit == separatorUnit && !insideQuotes {
            justSawCR = false
            finalizeCurrentCell()
        } else if unit == Unit.cr && !insideQuotes {
            justSawCR = true
            commitRow()
        } else if unit == Unit.lf && !insideQuotes {
            if justSawCR {
                justSawCR = false
            } else {
                commitRow()
            }
        } else {
            justSawCR = false
            appendToCell(rawBytes)
        }
    }

    private func appendToCell(_ rawBytes: [UInt8]) {
        guard cellsSeenInCurrentRow < configuration.maxColumns else { return }
        cellBytes.append(contentsOf: rawBytes)
        if cellBytes.count > configuration.maxCellByteSize {
            pendingError = .cellTooLarge
            finished = true
        }
    }

    private func finalizeCurrentCell() {
        if cellsSeenInCurrentRow < configuration.maxColumns {
            currentRowValues.append(decodeCell(cellBytes))
        }
        cellBytes.removeAll(keepingCapacity: true)
        cellsSeenInCurrentRow += 1
    }

    private func decodeCell(_ bytes: [UInt8]) -> String {
        switch stride {
        case .singleByte:
            // ISO-8859-1 never fails to decode (every byte is a valid code
            // point), so this fallback only makes sense — and is only
            // applied — for the 1-byte-per-unit encodings. Falling back to
            // it for 2-byte UTF-16 bytes would reinterpret each byte as its
            // own Latin-1 character and produce mojibake.
            if let decoded = String(bytes: bytes, encoding: .utf8) {
                return decoded
            }
            return String(bytes: bytes, encoding: .isoLatin1) ?? ""
        case .utf16LittleEndian:
            return String(bytes: bytes, encoding: .utf16LittleEndian) ?? ""
        case .utf16BigEndian:
            return String(bytes: bytes, encoding: .utf16BigEndian) ?? ""
        }
    }

    private func commitRow() {
        finalizeCurrentCell()

        if cellsSeenInCurrentRow > configuration.maxColumns {
            columnsTruncated = true
        }
        columnCount = max(columnCount, min(cellsSeenInCurrentRow, configuration.maxColumns))

        if rows.count >= configuration.maxRows {
            rowsTruncated = true
            finished = true
        } else {
            var cells: [String: String] = [:]
            for (index, value) in currentRowValues.enumerated() {
                cells["col_\(index)"] = value
            }
            rows.append(CSVRow(id: rows.count, cells: cells))
        }

        currentRowValues.removeAll(keepingCapacity: true)
        cellsSeenInCurrentRow = 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: every test added in Tasks 2–5 PASSES.

- [ ] **Step 5: Commit**

```bash
git add Shared/CSVStreamParser.swift QuickLookCSVTests/CSVStreamParserTests.swift
git commit -m "Add UTF-16 BOM/stride dispatch and per-cell ISO-8859-1 fallback decode"
```

---

## Task 6: File-based entry point and cross-conformance test against `CSVDocument`

**Files:**
- Modify: `Shared/CSVStreamParser.swift`
- Create: `QuickLookCSVTests/CSVDocumentTests.swift`
- Create: `QuickLookCSVTests/CSVStreamParserConformanceTests.swift`
- Modify: `QuickLookCSVTests` target membership (add `Info.plist`-free access to the fixture files: `test.csv`, `testHeight.csv`, `testWidth.csv`, `testMini.csv` as test resources)
- Modify: `QuickLookCSVTests` target membership (add `CSVDocument.h/.m`, `CSVRowObject.h/.m` **as test-only members**, plus a bridging header, so both the direct `CSVDocument` tests and the conformance test can call the legacy parser directly — this is the one place the new test target touches the legacy classes; production code in `QuickLookCSVPreview`/`QuickLookCSVThumbnail` never does)

**Interfaces:**
- Produces: `static func parse(fileAt url: URL, configuration: Configuration) throws -> ParsedCSVTable` on `CSVStreamParser`.

- [ ] **Step 1: Add the four fixture CSVs as test resources**

Add `QuickLookCSV/Resources/test.csv`, `testHeight.csv`, `testWidth.csv`, `testMini.csv` as resource members of the `QuickLookCSVTests` target (Build Phases > Copy Bundle Resources), so `Bundle.module`/`Bundle(for:)` can locate them at test time.

- [ ] **Step 2: Add `CSVDocument`/`CSVRowObject` as test-only members with a bridging header**

Add `QuickLookCSV/Source/CSVDocument.h`, `.m`, `CSVRowObject.h`, `.m` as members of `QuickLookCSVTests` (in addition to their existing legacy target membership — this does not modify those files or remove them from the legacy target). Create `QuickLookCSVTests/QuickLookCSVTests-Bridging-Header.h`:

```objc
#import "CSVDocument.h"
#import "CSVRowObject.h"
```

Set `SWIFT_OBJC_BRIDGING_HEADER` for the `QuickLookCSVTests` target to `QuickLookCSVTests/QuickLookCSVTests-Bridging-Header.h` via `UpdateTargetBuildSetting`.

- [ ] **Step 3: Write direct regression tests for the legacy `CSVDocument`**

`CSVDocument` has no automated test coverage today. Since this task is already wiring it into a test target for the conformance check, add direct characterization tests for its own documented behavior (quoting/escaping, separator auto-detection, `maxRows` cap) — these exercise the legacy parser in isolation, independent of `CSVStreamParser`. Create `QuickLookCSVTests/CSVDocumentTests.swift`:

```swift
import Testing
import Foundation

struct CSVDocumentTests {
    @Test func parsesEscapedQuoteInsideQuotedField() {
        let doc = CSVDocument()
        doc.autoDetectSeparator = false
        doc.separator = ","
        _ = doc.numRows(fromCSVString: "\"say \"\"hi\"\"\"\n", maxRows: 0, error: nil)
        #expect((doc.rows.first as? CSVRowObject)?.column(forKey: "col_0") == "say \"hi\"")
    }

    @Test func autoDetectsSemicolonSeparator() {
        let doc = CSVDocument()
        doc.autoDetectSeparator = true
        _ = doc.numRows(fromCSVString: "a;b;c\n1;2;3\n", maxRows: 0, error: nil)
        #expect(doc.separator == ";")
        // CSVDocument treats every scanned line as a data row (col_0, col_1, ...);
        // it never singles out row 0 as a header. So rows[0] is "a","b","c" and
        // rows[1] is the "1","2","3" data row.
        #expect((doc.rows[1] as? CSVRowObject)?.column(forKey: "col_1") == "2")
    }

    @Test func maxRowsCapKeepsExactlyMaxRowsRows() {
        let doc = CSVDocument()
        doc.autoDetectSeparator = false
        doc.separator = ","
        let count = doc.numRows(fromCSVString: "1\n2\n3\n4\n", maxRows: 2, error: nil)
        #expect(count > 2) // numRows reflects rows scanned, not rows kept
        #expect(doc.rows.count == 2)
        #expect((doc.rows[0] as? CSVRowObject)?.column(forKey: "col_0") == "1")
        #expect((doc.rows[1] as? CSVRowObject)?.column(forKey: "col_0") == "2")
    }
}
```

`CSVDocument.h` declares `rows` as a plain untyped `NSArray *` (no Objective-C lightweight generics), so Swift imports it as `[Any]`, not `[CSVRowObject]` — the `as? CSVRowObject` casts above are required, not optional style. Also note the actual bridged Swift name for `- (NSString *)columnForKey:` and for `- (NSUInteger)numRowsFromCSVString:maxRows:error:` — Xcode's ObjC-to-Swift import renamed the latter to `numRows(fromCSVString:maxRows:error:)` (the first parameter's leading noun becomes part of the base name). Use `column(forKey:)` (matching the `- (NSString *)columnForKey:` selector) consistently — the same name used in Step 4's conformance test below.

Run these 3 tests. Expected: all PASS immediately (this is characterization of already-correct, already-fixed legacy behavior, not new implementation) — if `maxRowsCapKeepsExactlyMaxRowsRows` fails with `doc.rows.count == 3`, the earlier off-by-one fix to `CSVDocument.m` has regressed; stop and investigate before continuing.

- [ ] **Step 4: Write the failing file-based parsing test**

Create `QuickLookCSVTests/CSVStreamParserConformanceTests.swift`:

```swift
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
```

(Use the same bridged `column(forKey:)`/`numRows(fromCSVString:maxRows:error:)` names determined in Step 3 — `legacyDoc.rows` is `[Any]`, so each element needs the `as! CSVRowObject` cast shown above.)

- [ ] **Step 5: Run tests to verify the new test fails**

Expected: compile error — `CSVStreamParser.parse(fileAt:configuration:)` not defined. (The Step 3 `CSVDocumentTests` should already be passing at this point.)

- [ ] **Step 6: Implement the file-based entry point**

Add to `Shared/CSVStreamParser.swift`:

```swift
extension CSVStreamParser {
    static func parse(fileAt url: URL, configuration: Configuration) throws -> ParsedCSVTable {
        // The security-scoped access window must cover every access to
        // this URL, not just the read loop below — including the file-size
        // lookup. Fetching the size separately, after this function
        // returns (and `defer` has already called
        // stopAccessingSecurityScopedResource()), would silently read 0 or
        // fail. That's why `ParsedCSVTable.fileSizeBytes` is populated
        // here rather than by a second, independent call in the view
        // controller.
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        let fileSize = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw ParseError.unreadableFile
        }
        defer { try? handle.close() }

        let parser = CSVStreamParser(configuration: configuration)
        while true {
            let chunkData = handle.readData(ofLength: configuration.chunkByteSize)
            if chunkData.isEmpty { break }
            let shouldStop = try parser.consume(Array(chunkData))
            if shouldStop { break }
        }
        var table = try parser.finish()
        table.fileSizeBytes = fileSize
        return table
    }
}
```

- [ ] **Step 7: Run tests to verify they pass**

Build/run `QuickLookCSVTests`. Expected: all tests PASS — the 3 `CSVDocumentTests` from Step 3, plus the 2 tests in `CSVStreamParserConformanceTests` (1 basic + 4 parameterized). If a mismatch is reported in `matchesLegacyCSVDocumentOutput`, inspect the specific fixture and row/column — the most likely causes are a fixture using an encoding other than UTF-8 (adjust the legacy-side `String(contentsOf:encoding:)` call to `.isoLatin1` or use `String(contentsOf:usedEncoding:)` to match `CSVStreamParser`'s own encoding choice for that file) or a fixture wider than `maxColumns`/`maxRows` defaults (raise the test's configuration values to match the fixture, not production defaults).

- [ ] **Step 8: Commit**

```bash
git add Shared/CSVStreamParser.swift QuickLookCSVTests QuickLookCSV.xcodeproj/project.pbxproj
git commit -m "Add CSVStreamParser file-based entry point, CSVDocument regression tests, and cross-conformance test"
```

---

## Task 7: Host app target (`QuickLookCSVApp`)

**Files:**
- Create host app target `QuickLookCSVApp` (Xcode project change)
- Create: `QuickLookCSVApp/QuickLookCSVApp.swift`
- Create: `QuickLookCSVApp/ContentView.swift`

**Interfaces:** None consumed from earlier tasks. Produces: an installable `.app` bundle that macOS uses solely as a container for the two extension targets built in Tasks 8–9.

- [ ] **Step 1: Create the target**

Use `XcodeNewTarget` with:
```
templateIdentifier: "com.apple.dt.unit.multiPlatform.app"
productName: "QuickLookCSVApp"
options: { "storageType": "None", "hostInCloudKit": "false", "testingSystem": "None" }
```

- [ ] **Step 2: Set the deployment target**

Use `UpdateTargetBuildSetting` on `QuickLookCSVApp`: `MACOSX_DEPLOYMENT_TARGET` = `13.0`.

- [ ] **Step 3: Replace the generated content view**

Overwrite `QuickLookCSVApp/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tablecells")
                .font(.system(size: 48))
            Text("QuickLook CSV")
                .font(.title)
            Text("This app installs the CSV preview and thumbnail extensions. You can quit this window — Quick Look uses the extensions automatically once the app is in /Applications.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 360)
            Button("Open Extensions Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
        .padding(40)
        .frame(minWidth: 420, minHeight: 280)
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 4: Build**

Run `BuildProject`. Expected: build succeeds, no errors.

- [ ] **Step 5: Commit**

```bash
git add QuickLookCSVApp QuickLookCSV.xcodeproj/project.pbxproj
git commit -m "Add QuickLookCSVApp host application target"
```

---

## Task 8: Preview Extension target (`QuickLookCSVPreview`)

**Files:**
- Create Preview Extension target `QuickLookCSVPreview`, embedded in `QuickLookCSVApp`
- Add `Shared/CSVStreamParser.swift`, `Shared/ParsedCSVTable.swift` as members of `QuickLookCSVPreview`
- Create: `QuickLookCSVPreview/CSVPreviewViewController.swift`
- Create: `QuickLookCSVPreview/CSVPreviewView.swift`
- Modify: `QuickLookCSVPreview/Info.plist`

**Interfaces:**
- Consumes: `CSVStreamParser`, `CSVStreamParser.Configuration.preview`, `ParsedCSVTable`, `CSVRow` (Tasks 1–6).

- [ ] **Step 1: Create the target**

Use `XcodeNewTarget` with:
```
templateIdentifier: "com.apple.dt.unit.multiPlatform.generic-extension"
productName: "QuickLookCSVPreview"
embedInAppNamed: "QuickLookCSVApp"
options: { "languageChoice": "Swift", "isUIExtension": "true" }
```

- [ ] **Step 2: Set the deployment target**

`UpdateTargetBuildSetting` on `QuickLookCSVPreview`: `MACOSX_DEPLOYMENT_TARGET` = `13.0`.

- [ ] **Step 3: Add the shared parser files to this target**

Add `Shared/CSVStreamParser.swift` and `Shared/ParsedCSVTable.swift` as additional members of the `QuickLookCSVPreview` target (multi-target membership with `QuickLookCSVTests`, per the spec's decision — these files are never added to the legacy `QuickLookCSV` target).

- [ ] **Step 4: Configure the extension's `Info.plist`**

Use `GetTargetBuildSettings` on `QuickLookCSVPreview` first to find the generated principal class name (the template names it after the product, e.g. `QuickLookCSVPreview.PreviewProvider` or similar — read the generated Swift entry-point file it created to get the exact name). Then use `AddInfoPlist` on `QuickLookCSVPreview` to set:

- `NSExtension` (dictionary) containing:
  - `NSExtensionPointIdentifier` = `com.apple.quicklook.preview`
  - `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).CSVPreviewViewController` (the class created in Step 5 below — set this only after Step 5, or update it then)
  - `NSExtensionAttributes` (dictionary) containing `QLSupportedContentTypes` = `["public.comma-separated-values-text", "public.tab-separated-values-text"]`

**Verification note:** the `AddInfoPlist` tool's `dictionaryArray` type is for arrays of dictionaries, not a single nested dictionary-of-dictionaries — if it cannot express this exact nested shape, read the current `QuickLookCSVPreview/Info.plist` via `XcodeRead` after target creation, and edit the `NSExtension` dictionary directly with `XcodeWrite` to the three keys above (this is the one file in this plan where direct Info.plist editing is appropriate, since it is a UI-less configuration file specific to this new target, not the legacy project file). Confirm the final `Info.plist` contains exactly those three keys under `NSExtension` before moving on.

- [ ] **Step 5: Implement the view controller**

Create `QuickLookCSVPreview/CSVPreviewViewController.swift`:

```swift
import Cocoa
import QuickLookUI
import SwiftUI

final class CSVPreviewViewController: NSViewController, QLPreviewingController {
    // Type-erased: this hosts either CSVPreviewView (the common case) or
    // CSVEmptyStateView (the ParseError.emptyFile case), so it can't be
    // pinned to one NSHostingController<...> generic type.
    private var hostingController: NSViewController?

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        do {
            // File size comes from `table.fileSizeBytes`, populated by
            // CSVStreamParser.parse(fileAt:) itself — it is the only place
            // that holds an active security-scoped access grant on `url`.
            // A second, independent file-attributes lookup here would run
            // after that access has already been released and would
            // silently fail or read stale/zero data.
            let table = try CSVStreamParser.parse(fileAt: url, configuration: .preview)
            show(CSVPreviewView(table: table))
            handler(nil)
        } catch CSVStreamParser.ParseError.emptyFile {
            // The design calls for a dedicated "empty file" state, not the
            // system's generic fallback preview — handled here rather than
            // by rethrowing to `handler`, which would hand control back to
            // Quick Look's own generic UI instead of ours.
            show(CSVEmptyStateView())
            handler(nil)
        } catch {
            handler(error)
        }
    }

    private func show<Content: View>(_ content: Content) {
        let hosting = NSHostingController(rootView: content)
        hostingController = hosting

        addChild(hosting)
        hosting.view.frame = view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        view.addSubview(hosting.view)
    }
}
```

- [ ] **Step 6: Implement the SwiftUI views**

Create `QuickLookCSVPreview/CSVPreviewView.swift`:

```swift
import SwiftUI

private struct ColumnKey: Identifiable {
    let id: String
    var key: String { id }
}

struct CSVEmptyStateView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tablecells")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("This file is empty")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CSVPreviewView: View {
    let table: ParsedCSVTable

    private var displayedColumns: [ColumnKey] {
        table.columnKeys.map(ColumnKey.init)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            infoBanner
            Table(table.rows) {
                TableColumnForEach(displayedColumns) { column in
                    // SwiftUI's Table always reserves header row space on
                    // macOS 13 (no API to hide it) — an empty title avoids
                    // leaking the parser's internal "col_0", "col_1", ...
                    // placeholder keys to the user, matching the legacy
                    // HTML preview, which never showed a header row at all.
                    TableColumn("") { row in
                        // A single very long field must not wrap to
                        // multiple lines: that would blow out this row's
                        // height in a native Table and badly degrade
                        // scroll performance across the whole table.
                        Text(row.value(forColumnKey: column.key))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
    }

    private var infoBanner: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("\(table.columnKeys.count) column(s), \(table.rows.count) row(s)")
                Text(ByteCountFormatter.string(fromByteCount: table.fileSizeBytes, countStyle: .file))
                    .foregroundStyle(.secondary)
            }
            if table.rowsTruncated {
                Text("Only the first \(table.rows.count) rows are being displayed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if table.columnsTruncated {
                Text("Only the first \(table.columnKeys.count) columns are being displayed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }
}
```

- [ ] **Step 7: Build**

Run `BuildProject`. Expected: build succeeds. Fix any signature mismatch reported for `QLPreviewingController` (the exact `preparePreviewOfFile` closure type is `@escaping @Sendable ((any Error)?) -> Void` per the framework — adjust the parameter type in Step 5 if the compiler requires `@Sendable`).

- [ ] **Step 8: Commit**

```bash
git add QuickLookCSVPreview QuickLookCSV.xcodeproj/project.pbxproj
git commit -m "Add QuickLookCSVPreview extension with SwiftUI Table rendering"
```

---

## Task 9: Thumbnail Extension target (`QuickLookCSVThumbnail`)

**Files:**
- Create Thumbnail Extension target `QuickLookCSVThumbnail`, embedded in `QuickLookCSVApp`
- Add `Shared/CSVStreamParser.swift`, `Shared/ParsedCSVTable.swift` as members of `QuickLookCSVThumbnail`
- Create: `QuickLookCSVThumbnail/CSVThumbnailProvider.swift`
- Modify: `QuickLookCSVThumbnail/Info.plist`

**Interfaces:**
- Consumes: `CSVStreamParser`, `CSVStreamParser.Configuration.thumbnail`, `ParsedCSVTable`, `CSVRow` (Tasks 1–6).

- [ ] **Step 1: Create the target**

Use `XcodeNewTarget` with:
```
templateIdentifier: "com.apple.dt.unit.multiPlatform.generic-extension"
productName: "QuickLookCSVThumbnail"
embedInAppNamed: "QuickLookCSVApp"
options: { "languageChoice": "Swift", "isUIExtension": "false" }
```

- [ ] **Step 2: Set the deployment target**

`UpdateTargetBuildSetting` on `QuickLookCSVThumbnail`: `MACOSX_DEPLOYMENT_TARGET` = `13.0`.

- [ ] **Step 3: Add the shared parser files to this target**

Add `Shared/CSVStreamParser.swift` and `Shared/ParsedCSVTable.swift` as additional members of `QuickLookCSVThumbnail`.

- [ ] **Step 4: Configure the extension's `Info.plist`**

Use `GetTargetBuildSettings` on `QuickLookCSVThumbnail` to confirm the generated principal class name, then use `AddInfoPlist` on `QuickLookCSVThumbnail` to set an `NSExtension` dictionary containing:
  - `NSExtensionPointIdentifier` = `com.apple.quicklook.thumbnail`
  - `NSExtensionPrincipalClass` = `$(PRODUCT_MODULE_NAME).CSVThumbnailProvider` (the class created in Step 5 below)
  - `NSExtensionAttributes` (dictionary) containing `QLSupportedContentTypes` = `["public.comma-separated-values-text", "public.tab-separated-values-text"]`

**Verification note:** if `AddInfoPlist` cannot express this nested dictionary-of-dictionaries shape directly, read the current `QuickLookCSVThumbnail/Info.plist` via `XcodeRead` after target creation and edit the `NSExtension` dictionary directly with `XcodeWrite` to the three keys above (same exception as Task 8 — a new target's own configuration file, not the legacy project file). Confirm the final `Info.plist` contains exactly those three keys under `NSExtension` before moving on.

- [ ] **Step 5: Implement the thumbnail provider**

Create `QuickLookCSVThumbnail/CSVThumbnailProvider.swift` — this ports the drawing logic from the legacy `GenerateThumbnailForURL.m` (grid, alternating row background, aspect-ratio-adjusted final size, "csv"/"tab" badge) to consume `ParsedCSVTable`.

`QLThumbnailReply.init(contextSize:currentContextDrawing:)` — confirmed via the QuickLookThumbnailing documentation as `convenience init(contextSize: CGSize, currentContextDrawing drawingBlock: @escaping () -> Bool)` — takes a **no-argument** closure and expects it to draw into `NSGraphicsContext.current`, which the framework sets up for you; there is no `CGContext` parameter to capture, and no manual bitmap context creation/teardown as the legacy code needed.

Unlike the legacy code, `contextSize` must be known *before* the drawing block runs (it's a constructor argument, not something decided mid-draw), so measuring the aspect-adjusted final size — legacy did this by drawing into an oversized square canvas and cropping afterward — has to happen as a separate pass here, using the same text measurements the draw pass will use, before constructing the reply:

```swift
import QuickLookThumbnailing
import AppKit

final class CSVThumbnailProvider: QLThumbnailProvider {
    private static let aspect: CGFloat = 0.8

    override func provideThumbnail(for request: QLFileThumbnailRequest, _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        do {
            let table = try CSVStreamParser.parse(fileAt: request.fileURL, configuration: .thumbnail)
            guard !table.rows.isEmpty else {
                handler(nil, nil)
                return
            }

            let layout = Self.measureLayout(for: table, maxSize: request.maximumSize)
            let reply = QLThumbnailReply(contextSize: layout.size, currentContextDrawing: {
                Self.draw(table: table, layout: layout)
            })
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }

    private struct Layout {
        let size: CGSize
        let rowHeight: CGFloat
        let font: NSFont
        let columnWidths: [CGFloat]
        let badgeMaxSize: CGFloat
    }

    private static func measureLayout(for table: ParsedCSVTable, maxSize: CGSize) -> Layout {
        let rowCount = max(4, min(table.rows.count, 18))
        let rowHeight = ceil(maxSize.height / CGFloat(rowCount))
        let fontSize = round(0.666 * rowHeight)
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textPadding: CGFloat = 5

        var columnWidths: [CGFloat] = []
        var totalWidth: CGFloat = 0
        for key in table.columnKeys {
            if totalWidth > maxSize.width { break }
            var maxCellWidth: CGFloat = 0
            for row in table.rows {
                let text = row.value(forColumnKey: key) as NSString
                maxCellWidth = max(maxCellWidth, text.size(withAttributes: attributes).width)
            }
            let columnWidth = maxCellWidth + 2 * textPadding
            columnWidths.append(columnWidth)
            totalWidth += columnWidth
        }

        var usedWidth = totalWidth
        var usedHeight = CGFloat(table.rows.count) * rowHeight
        let badgeMaxSize: CGFloat

        if (usedWidth > maxSize.width && usedHeight > maxSize.height) || usedWidth <= usedHeight {
            badgeMaxSize = usedHeight
            usedWidth = usedHeight * aspect
        } else {
            badgeMaxSize = usedWidth
            usedHeight = usedWidth * aspect
        }

        return Layout(
            size: CGSize(width: ceil(usedWidth), height: ceil(usedHeight)),
            rowHeight: rowHeight, font: font, columnWidths: columnWidths, badgeMaxSize: badgeMaxSize
        )
    }

    @discardableResult
    private static func draw(table: ParsedCSVTable, layout: Layout) -> Bool {
        let textPadding: CGFloat = 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: NSColor(calibratedWhite: 0.25, alpha: 1)
        ]
        let rowBG = NSColor.white
        let altRowBG = NSColor(calibratedWhite: 0.9, alpha: 1)
        let borderColor = NSColor(calibratedWhite: 0.67, alpha: 1)

        var cellX: CGFloat = 0
        for (columnIndex, key) in table.columnKeys.enumerated() {
            guard columnIndex < layout.columnWidths.count else { break }
            let columnWidth = layout.columnWidths[columnIndex]

            for (rowIndex, row) in table.rows.enumerated() {
                // NSGraphicsContext.current here uses AppKit's unflipped,
                // bottom-left-origin coordinate system, so row 0 (drawn
                // first, expected at the top) must be placed at the
                // highest Y, not Y=0.
                let topY = CGFloat(rowIndex) * layout.rowHeight
                let y = layout.size.height - topY - layout.rowHeight
                let rowRect = CGRect(x: cellX, y: y, width: columnWidth, height: layout.rowHeight)

                if columnIndex == 0 {
                    // Paint the full row width in one shot during the
                    // first column's pass — not just this column's own
                    // width — otherwise every column past the first is
                    // left with a transparent background.
                    let fullRowRect = CGRect(x: 0, y: y, width: layout.size.width, height: layout.rowHeight)
                    (rowIndex % 2 == 0 ? rowBG : altRowBG).setFill()
                    fullRowRect.fill()
                } else {
                    borderColor.setStroke()
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: cellX, y: rowRect.minY))
                    path.line(to: CGPoint(x: cellX, y: rowRect.maxY))
                    path.stroke()
                }

                let text = row.value(forColumnKey: key) as NSString
                let textRect = CGRect(x: cellX + textPadding, y: y, width: columnWidth - 2 * textPadding, height: layout.rowHeight)
                text.draw(in: textRect, withAttributes: attributes)
            }
            cellX += columnWidth
        }

        let badgeString = (table.isTabSeparated ? "tab" : "csv") as NSString
        let badgeFontSize = ceil(layout.badgeMaxSize * 0.28)
        let badgeShadow = NSShadow()
        badgeShadow.shadowOffset = NSSize(width: 0, height: 0)
        badgeShadow.shadowBlurRadius = badgeFontSize * 0.01
        badgeShadow.shadowColor = NSColor.white
        let badgeAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: badgeFontSize),
            .foregroundColor: NSColor(calibratedRed: 0.05, green: 0.25, blue: 0.1, alpha: 1),
            .shadow: badgeShadow
        ]
        let badgeSize = badgeString.size(withAttributes: badgeAttributes)
        let badgeX = (layout.size.width / 2) - (badgeSize.width / 2)
        let badgeY = 0.025 * layout.badgeMaxSize
        badgeString.draw(at: CGPoint(x: badgeX, y: badgeY), withAttributes: badgeAttributes)

        return true
    }
}
```

- [ ] **Step 6: Build**

Run `BuildProject`. Expected: build succeeds. `QLFileThumbnailRequest.fileURL`/`.maximumSize` should be verified against the framework headers if the compiler reports a mismatch.

- [ ] **Step 7: Commit**

```bash
git add QuickLookCSVThumbnail QuickLookCSV.xcodeproj/project.pbxproj
git commit -m "Add QuickLookCSVThumbnail extension reusing the Core Graphics drawing approach"
```

---

## Task 10: Manual verification pass

**Files:** None (verification only).

- [ ] **Step 1: Full build**

Run `BuildProject` for the whole scheme. Expected: `QuickLookCSV` (legacy), `QuickLookCSVApp`, `QuickLookCSVPreview`, `QuickLookCSVThumbnail`, and `QuickLookCSVTests` all build with no errors.

- [ ] **Step 2: Run the full test suite**

Run `RunAllTests`. Expected: every test from Tasks 1–6 passes, including the 4 cross-conformance tests against the real fixture files.

- [ ] **Step 3: Install and exercise the host app**

Run `RunProject` (or manually copy the built `QuickLookCSVApp.app` to `/Applications` and launch it once) so macOS registers the two embedded extensions. Confirm via System Settings > Login Items & Extensions > Quick Look that `QuickLookCSVPreview` and `QuickLookCSVThumbnail` are listed and enabled.

- [ ] **Step 4: Quick Look the fixtures**

In Finder, select `QuickLookCSV/Resources/test.csv`, `testHeight.csv`, `testWidth.csv`, `testMini.csv` one at a time and press Space. Confirm: the native `Table` renders with correct columns/rows, column headers are sortable by click, and the row/column truncation banner appears only for fixtures that actually exceed 500 rows / 50 columns. Confirm thumbnails in Finder icon view show the grid + "csv"/"tab" badge.

- [ ] **Step 5: Confirm the legacy target is untouched**

```bash
git diff master -- QuickLookCSV/Source/CSVDocument.m QuickLookCSV/Source/CSVDocument.h QuickLookCSV/Source/CSVRowObject.m QuickLookCSV/Source/CSVRowObject.h QuickLookCSV/Source/GeneratePreviewForURL.m QuickLookCSV/Source/GenerateThumbnailForURL.m
```

Expected: empty diff (no changes to any legacy source file across this entire plan).
