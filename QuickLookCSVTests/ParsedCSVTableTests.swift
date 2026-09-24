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
