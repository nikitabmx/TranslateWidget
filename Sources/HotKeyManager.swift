import Cocoa
import Carbon.HIToolbox

/// A global hotkey registered via Carbon, with its combination persisted in
/// `UserDefaults`. It can be changed at runtime from the preferences window;
/// `onChange` fires so the UI can refresh. One instance per command.
final class HotKeyManager {
    /// Opens the widget (picking up selected text). Default ⌥⌘T.
    static let shared = HotKeyManager(id: 1, defaultsPrefix: "hotkey",
                                      defaultKeyCode: UInt32(kVK_ANSI_T),
                                      defaultModifiers: UInt32(cmdKey | optionKey))
    /// Screenshots a piece of the screen and translates its text. Default ⌥⇧⌘T.
    static let screenshot = HotKeyManager(id: 2, defaultsPrefix: "hotkey.screenshot",
                                          defaultKeyCode: UInt32(kVK_ANSI_T),
                                          defaultModifiers: UInt32(cmdKey | optionKey | shiftKey))
    static let all = [shared, screenshot]

    private init(id: UInt32, defaultsPrefix: String, defaultKeyCode: UInt32, defaultModifiers: UInt32) {
        hotKeyID = id
        keyCodeKey = defaultsPrefix + ".keyCode"
        modifiersKey = defaultsPrefix + ".modifiers"
        self.defaultKeyCode = defaultKeyCode
        self.defaultModifiers = defaultModifiers
    }

    /// Called after the stored hotkey changes (update or reset).
    var onChange: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    fileprivate let hotKeyID: UInt32
    private let keyCodeKey: String
    private let modifiersKey: String
    private let defaultKeyCode: UInt32
    private let defaultModifiers: UInt32

    var defaultDisplayString: String {
        HotKeyManager.displayString(keyCode: defaultKeyCode, modifiers: defaultModifiers)
    }

    var keyCode: UInt32 {
        guard UserDefaults.standard.object(forKey: keyCodeKey) != nil else { return defaultKeyCode }
        return UInt32(UserDefaults.standard.integer(forKey: keyCodeKey))
    }

    var modifiers: UInt32 {
        guard UserDefaults.standard.object(forKey: modifiersKey) != nil else { return defaultModifiers }
        return UInt32(UserDefaults.standard.integer(forKey: modifiersKey))
    }

    // MARK: - Lifecycle

    /// Install the global handler and register the stored hotkey. Call once.
    func start(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        installHandlerIfNeeded()
        registerHotKey()
    }

    /// Store a new combination and re-register it immediately.
    func update(keyCode: UInt32, modifiers: UInt32) {
        UserDefaults.standard.set(Int(keyCode), forKey: keyCodeKey)
        UserDefaults.standard.set(Int(modifiers), forKey: modifiersKey)
        registerHotKey()
        onChange?()
    }

    /// Restore the default combination.
    func resetToDefault() {
        UserDefaults.standard.removeObject(forKey: keyCodeKey)
        UserDefaults.standard.removeObject(forKey: modifiersKey)
        registerHotKey()
        onChange?()
    }

    /// Temporarily disable the hotkey (used while recording a new one).
    func suspend() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// Re-enable after `suspend()`.
    func resume() {
        registerHotKey()
    }

    // MARK: - Carbon plumbing

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        // Every instance's handler sees every hotkey press — each one reacts
        // only to its own id and passes the rest on.
        InstallEventHandler(GetApplicationEventTarget(),
                            { (_, event, userData) -> OSStatus in
                                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                                let manager = Unmanaged<HotKeyManager>
                                    .fromOpaque(userData)
                                    .takeUnretainedValue()
                                var pressed = EventHotKeyID()
                                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                                               EventParamType(typeEventHotKeyID), nil,
                                                               MemoryLayout<EventHotKeyID>.size, nil, &pressed)
                                guard status == noErr, pressed.id == manager.hotKeyID else {
                                    return OSStatus(eventNotHandledErr)
                                }
                                DispatchQueue.main.async { manager.onTrigger?() }
                                return noErr
                            },
                            1,
                            &spec,
                            Unmanaged.passUnretained(self).toOpaque(),
                            &eventHandler)
    }

    private func registerHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        let id = EventHotKeyID(signature: OSType(0x54_57_47_54), id: hotKeyID) // 'TWGT'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { // e.g. the combination is taken by another app
            DebugLog.log("hotkey \(currentDisplayString) (id \(hotKeyID)) failed to register: \(status)")
        }
    }

    // MARK: - Display helpers

    var currentDisplayString: String {
        HotKeyManager.displayString(keyCode: keyCode, modifiers: modifiers)
    }

    /// Convert Cocoa modifier flags (from an `NSEvent`) to a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    /// Human-readable shortcut, e.g. "⌥⌘T". Modifier order follows Apple's HIG.
    static func displayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyName(keyCode)
        return result
    }

    private static func keyName(_ keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? "Key\(keyCode)"
    }

    private static let keyNames: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
        kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
        kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
        kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
        kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
        kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Escape: "⎋",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Grave: "`",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12",
    ]
}
