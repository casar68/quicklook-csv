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
    private var insideQuotes = false
    private var pendingCloseQuote = false
    private var separatorUnit: UInt16 = SeparatorCandidate.comma.codeUnit
    private var prefixBuffer: [UInt8] = []
    private var prefixComplete = false
    private var isTabSeparated = false

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
}
