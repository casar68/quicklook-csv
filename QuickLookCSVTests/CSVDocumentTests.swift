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
