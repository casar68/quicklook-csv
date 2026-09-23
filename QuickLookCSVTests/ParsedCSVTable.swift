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
