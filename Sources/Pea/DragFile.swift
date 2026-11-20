import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: Draggable file

struct DragFile: NSViewRepresentable {
    let url: URL
    let onMoved: () -> Void

    func makeNSView(context: Context) -> DragNSView { DragNSView(url: url, onMoved: onMoved) }
    func updateNSView(_ v: DragNSView, context: Context) { v.onMoved = onMoved }
}

final class DragNSView: NSView, NSDraggingSource {
    let url: URL
    var onMoved: () -> Void
    private var image: NSImage

    init(url: URL, onMoved: @escaping () -> Void) {
        self.url = url
        self.onMoved = onMoved
        self.image = NSWorkspace.shared.icon(forFile: url.path)
        super.init(frame: .zero)
        let req = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 240, height: 240),
            scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .all)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { [weak self] rep, _ in
            guard let cg = rep?.cgImage else { return }
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            DispatchQueue.main.async { self?.image = img; self?.needsDisplay = true }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var fitted: NSRect {
        let s = image.size
        guard s.width > 0, s.height > 0 else { return bounds }
        let k = min(bounds.width / s.width, bounds.height / s.height)
        let w = s.width * k, h = s.height * k
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        image.draw(in: fitted)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(fitted, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // Move-only: the file leaves Downloads and lands where it is dropped.
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        if operation.contains(.move) { onMoved() }
    }
}

// MARK: Window

/// Hidden title bar, fixed size, dark, draggable by its background. In menu bar mode the window just closes.
struct WindowConfig: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            if Settings.menuBarMode { w.close(); return }
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.styleMask.insert(.fullSizeContentView)
            w.styleMask.remove(.resizable)
            w.standardWindowButton(.zoomButton)?.isEnabled = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.center()
        }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {}
}
