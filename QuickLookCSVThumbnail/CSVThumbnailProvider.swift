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
