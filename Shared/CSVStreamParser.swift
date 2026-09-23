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
            if finished { break }
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
