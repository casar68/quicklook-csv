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
