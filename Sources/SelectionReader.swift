import Cocoa
import ApplicationServices
import Carbon.HIToolbox

/// Reads the text selected in the frontmost app, so the hotkey can open the
/// widget with it. The Accessibility API goes first (no side effects); apps
/// that don't expose their selection that way (Chromium/Electron apps, some
/// web views) get a synthetic ⌘C, with the clipboard put back right after.
///
/// Both routes need the Accessibility permission. Without it nothing is read,
/// and macOS is asked to show its permission prompt.
enum SelectionReader {
    enum Result {
        case text(String)
        case nothing
        case needsPermission // Accessibility isn't granted (or went stale after a rebuild)
    }

    /// For the debug log: which permissions macOS grants this build.
    static func logTrust() {
        DebugLog.log("accessibility trusted: \(AXIsProcessTrusted()), screen recording: \(CGPreflightScreenCaptureAccess()) (\(Bundle.main.bundlePath))")
    }

    /// Calls back on the main thread.
    static func read(completion: @escaping (Result) -> Void) {
        guard AXIsProcessTrusted() else {
            DebugLog.log("selection: Accessibility not granted")
            // macOS shows its prompt only while the app isn't in the list yet (e.g.
            // after its stale entry was removed), so asking every time is fine.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            completion(.needsPermission)
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            DebugLog.log("selection: our own app is in front")
            completion(.nothing)
            return
        }
        let answer = viaAccessibility()
        let chromium = isChromiumBased(app)
        DebugLog.log("selection: front=\(app.bundleIdentifier ?? "?") ax=\(answer.kind) chromium=\(chromium)")
        switch answer {
        case .text(let text):
            completion(.text(text))
        case .nothingSelected where !chromium:
            completion(.nothing)
        case .nothingSelected, .unsupported:
            viaCopy { text in
                DebugLog.log("selection: ⌘C fallback → \(text?.count ?? 0) chars")
                completion(text.map(Result.text) ?? .nothing)
            }
        }
    }

    /// Chromium and Electron apps (Chrome, Edge, Slack, VS Code, Claude…) often
    /// report an empty accessibility selection even with text selected, so they
    /// get the ⌘C route. They're recognizable by their "<Name> Framework" bundle.
    private static func isChromiumBased(_ app: NSRunningApplication) -> Bool {
        guard let frameworks = app.bundleURL?.appendingPathComponent("Contents/Frameworks"),
              let names = try? FileManager.default.contentsOfDirectory(atPath: frameworks.path) else { return false }
        return names.contains { $0.hasSuffix(" Framework.framework") }
    }

    // MARK: - Accessibility

    private enum AXResult {
        case text(String)
        case nothingSelected // the app answered: the selection is empty
        case unsupported     // the app doesn't expose its selection

        /// For the debug log — never the text itself.
        var kind: String {
            switch self {
            case .text(let text): return "text(\(text.count) chars)"
            case .nothingSelected: return "empty"
            case .unsupported: return "unsupported"
            }
        }
    }

    private static func viaAccessibility() -> AXResult {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25) // never hang on a busy app
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unsupported }
        var selected: CFTypeRef?
        let element = focused as! AXUIElement // type checked above
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String else { return .unsupported }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .nothingSelected : .text(text)
    }

    // MARK: - ⌘C fallback

    private static func viaCopy(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        let before = pasteboard.changeCount

        // ⌥/⌃/⇧ from the hotkey may still be held; ⌥⌘C means something else in
        // many apps, so give the user a moment to let go of them first.
        waitForModifierRelease(until: Date().addingTimeInterval(0.4)) {
            postCommandC()
            let deadline = Date().addingTimeInterval(0.35)
            func check() {
                if pasteboard.changeCount != before {
                    // Copying files in Finder puts their names on the clipboard — not a text selection.
                    let copiedFiles = pasteboard.types?.contains(.fileURL) ?? false
                    let text = copiedFiles ? nil : pasteboard.string(forType: .string)
                    restore(saved, to: pasteboard)
                    let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    completion(trimmed.isEmpty ? nil : text)
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check)
                } else {
                    completion(nil) // nothing got copied — no selection
                }
            }
            check()
        }
    }

    private static func waitForModifierRelease(until deadline: Date, then action: @escaping () -> Void) {
        let held = NSEvent.modifierFlags.intersection([.option, .control, .shift])
        if held.isEmpty || Date() >= deadline {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                waitForModifierRelease(until: deadline, then: action)
            }
        }
    }

    private static func postCommandC() {
        let source = CGEventSource(stateID: .privateState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }

    /// A deep copy of everything on the clipboard, so it can be put back.
    private static func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
    }

    private static func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}
