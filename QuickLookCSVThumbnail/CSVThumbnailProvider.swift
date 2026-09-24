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

    private static func measuredColumns(
        for table: ParsedCSVTable, fontSize: CGFloat, textPadding: CGFloat
    ) -> (widths: [CGFloat], total: CGFloat, font: NSFont) {
        let font = NSFont.systemFont(ofSize: fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var widths: [CGFloat] = []
        var total: CGFloat = 0
        for key in table.columnKeys {
            var maxCellWidth: CGFloat = 0
            for row in table.rows {
                let text = row.value(forColumnKey: key) as NSString
                maxCellWidth = max(maxCellWidth, text.size(withAttributes: attributes).width)
            }
            let columnWidth = maxCellWidth + 2 * textPadding
            widths.append(columnWidth)
            total += columnWidth
        }
        return (widths, total, font)
    }

    private static func measureLayout(for table: ParsedCSVTable, maxSize: CGSize) -> Layout {
        let rowCount = max(4, min(table.rows.count, 18))
        let textPadding: CGFloat = 5

        // Pass 1: measure at a fixed reference row height, independent of
        // maxSize's magnitude, to learn this table's natural width/height
        // proportions (short numeric cells measure narrow; long text cells
        // measure wide).
        let referenceRowHeight: CGFloat = 20
        let referenceFontSize = round(0.666 * referenceRowHeight)
        let reference = measuredColumns(for: table, fontSize: referenceFontSize, textPadding: textPadding)
        let naturalWidth = max(reference.total, 1)
        let naturalHeight = CGFloat(rowCount) * referenceRowHeight

        // The largest page-like (fixed 0.8 aspect ratio) box that fits
        // within maxSize, regardless of the table's own proportions.
        var boxHeight = maxSize.height
        var boxWidth = boxHeight * aspect
        if boxWidth > maxSize.width {
            boxWidth = maxSize.width
            boxHeight = boxWidth / aspect
        }

        // Pass 2: scale the natural measurement up (or down) so the
        // content fills as much of that box as possible without
        // overflowing either dimension. This is what keeps the returned
        // contextSize close to maxSize as QLThumbnailReply's documentation
        // requires — an absolute size derived purely from the content's
        // own (possibly tiny) natural dimensions, with no scale-up step,
        // left most of a large requested icon size blank.
        let scale = min(boxWidth / naturalWidth, boxHeight / naturalHeight)
        let rowHeight = ceil(referenceRowHeight * scale)
        let fontSize = round(referenceFontSize * scale)
        let final = measuredColumns(for: table, fontSize: fontSize, textPadding: textPadding)

        let usedWidth = max(final.total, 1)
        let usedHeight = CGFloat(table.rows.count) * rowHeight
        let badgeMaxSize = max(usedWidth, usedHeight)

        return Layout(
            size: CGSize(width: ceil(usedWidth), height: ceil(usedHeight)),
            rowHeight: rowHeight, font: final.font, columnWidths: final.widths, badgeMaxSize: badgeMaxSize
        )
    }

    @discardableResult
    private static func draw(table: ParsedCSVTable, layout: Layout) -> Bool {
        let textPadding: CGFloat = 5
        // "calibrated" NSColor APIs resolve against a device color profile,
        // which an off-screen thumbnail bitmap context may not have — use
        // explicit sRGB-based APIs instead so colors are guaranteed to
        // render rather than silently falling back to white/transparent.
        let attributes: [NSAttributedString.Key: Any] = [
            .font: layout.font,
            .foregroundColor: NSColor(white: 0.25, alpha: 1)
        ]
        let rowBG = NSColor.white
        let altRowBG = NSColor(white: 0.9, alpha: 1)
        let borderColor = NSColor(white: 0.67, alpha: 1)

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
            .foregroundColor: NSColor(srgbRed: 0.05, green: 0.25, blue: 0.1, alpha: 1),
            .shadow: badgeShadow
        ]
        let badgeSize = badgeString.size(withAttributes: badgeAttributes)
        let badgeX = (layout.size.width / 2) - (badgeSize.width / 2)
        let badgeY = 0.025 * layout.badgeMaxSize
        badgeString.draw(at: CGPoint(x: badgeX, y: badgeY), withAttributes: badgeAttributes)

        return true
    }
}
