import Cocoa
import UniformTypeIdentifiers
import Vision

/// On-device OCR (Vision) for images pasted or dropped into the widget.
enum TextRecognizer {
    enum RecognitionError: LocalizedError {
        case unreadableImage
        case noText

        var errorDescription: String? {
            switch self {
            case .unreadableImage: return "Couldn't read this image"
            case .noText: return "No text found in the image"
            }
        }
    }

    // MARK: - Pasteboard

    private static let imageFileOptions: [NSPasteboard.ReadingOptionKey: Any] = [
        .urlReadingFileURLsOnly: true,
        .urlReadingContentsConformToTypes: [UTType.image.identifier],
    ]

    /// Whether the pasteboard carries an image: an image file (from Finder) or
    /// image data (a screenshot, a picture copied from a browser). Plain text
    /// wins, so copying rich text never turns into OCR.
    static func hasImage(on pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(forClasses: [NSURL.self], options: imageFileOptions) { return true }
        if hasText(on: pasteboard) { return false }
        return NSImage.canInit(with: pasteboard)
    }

    static func image(from pasteboard: NSPasteboard) -> NSImage? {
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: imageFileOptions) as? [URL])?.first {
            return NSImage(contentsOf: url)
        }
        guard !hasText(on: pasteboard), NSImage.canInit(with: pasteboard) else { return nil }
        return NSImage(pasteboard: pasteboard)
    }

    private static func hasText(on pasteboard: NSPasteboard) -> Bool {
        guard let text = pasteboard.string(forType: .string) else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Recognition

    /// The image's text, line by line. `preferredLanguages` are plain codes
    /// ("ru", "en") used as hints on top of automatic language detection.
    static func recognizeText(in image: NSImage, preferredLanguages: [String]) async throws -> String {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RecognitionError.unreadableImage
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.automaticallyDetectsLanguage = true
                let supported = (try? request.supportedRecognitionLanguages()) ?? []
                let hints = preferredLanguages.compactMap { code in
                    supported.first { $0 == code || $0.hasPrefix(code + "-") }
                }
                if !hints.isEmpty { request.recognitionLanguages = hints }
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    let text = lines.joined(separator: "\n")
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.resume(throwing: RecognitionError.noText)
                    } else {
                        continuation.resume(returning: text)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Accepts images dropped anywhere on the panel outside the input (the input's
/// text view handles drops over itself).
final class ImageDropView: NSView {
    var onImage: ((NSImage) -> Void)?
    var onHover: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard TextRecognizer.hasImage(on: sender.draggingPasteboard) else { return [] }
        onHover?(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(false) }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        TextRecognizer.hasImage(on: sender.draggingPasteboard)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onHover?(false)
        guard let image = TextRecognizer.image(from: sender.draggingPasteboard) else { return false }
        onImage?(image)
        return true
    }
}
