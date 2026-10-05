import Cocoa

/// An `NSTextView` that paints a placeholder string while empty, and hands
/// images pasted or dropped onto it to `onImage` (for text recognition).
final class PlaceholderTextView: NSTextView {
    var placeholder: String = "" {
        didSet { needsDisplay = true }
    }

    /// An image pasted (⌘V) or dropped here. Set only on the editable input.
    var onImage: ((NSImage) -> Void)? {
        didSet { updateDragTypeRegistration() } // pick up the image types below
    }
    /// An image drag entering (true) / leaving (false) — for the drop highlight.
    var onImageDragHover: ((Bool) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            // Noticeably darker than the default placeholder/secondary gray.
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.62),
            .font: font ?? .systemFont(ofSize: 19),
        ]
        let padding = textContainer?.lineFragmentPadding ?? 0
        let origin = NSPoint(x: textContainerInset.width + padding,
                             y: textContainerInset.height)
        placeholder.draw(at: origin, withAttributes: attributes)
    }

    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }

    // MARK: - Images

    override func paste(_ sender: Any?) {
        if isEditable, let onImage, let image = TextRecognizer.image(from: .general) {
            onImage(image)
            return
        }
        super.paste(sender)
    }

    // A plain-text view doesn't take image data by default — accept it here.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        guard onImage != nil else { return super.acceptableDragTypes }
        return super.acceptableDragTypes + [.fileURL, .tiff, .png]
    }

    private func isImageDrag(_ sender: NSDraggingInfo) -> Bool {
        isEditable && onImage != nil && TextRecognizer.hasImage(on: sender.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isImageDrag(sender) else { return super.draggingEntered(sender) }
        onImageDragHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        isImageDrag(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onImageDragHover?(false)
        super.draggingExited(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isImageDrag(sender) || super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isImageDrag(sender), let image = TextRecognizer.image(from: sender.draggingPasteboard) else {
            return super.performDragOperation(sender)
        }
        onImageDragHover?(false)
        onImage?(image)
        return true
    }
}
