import Cocoa
import Carbon.HIToolbox

/// A button that records a keyboard shortcut for one hotkey. Click to start
/// recording, then press a combination with at least one modifier. Escape cancels.
final class ShortcutRecorderView: NSButton {
    /// Reports a newly recorded (keyCode, carbonModifiers) pair.
    var onChange: ((UInt32, UInt32) -> Void)?

    private let manager: HotKeyManager
    private var isRecording = false
    private var monitor: Any?

    init(manager: HotKeyManager) {
        self.manager = manager
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(toggleRecording)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Update the displayed shortcut from the current stored value.
    func refresh() {
        title = isRecording
            ? "Press shortcut…"
            : manager.currentDisplayString
    }

    @objc private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        // Disable the global hotkeys so pressing an existing combo won't trigger it.
        HotKeyManager.all.forEach { $0.suspend() }
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handle(event)
            return nil // swallow keystrokes while recording
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        HotKeyManager.all.forEach { $0.resume() }
        refresh()
    }

    private func handle(_ event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            stopRecording()
            return
        }
        let carbon = HotKeyManager.carbonModifiers(from: event.modifierFlags)
        guard carbon != 0 else { return } // require at least one modifier
        onChange?(UInt32(event.keyCode), carbon)
        stopRecording()
    }
}
