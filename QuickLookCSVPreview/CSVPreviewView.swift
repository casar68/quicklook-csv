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
