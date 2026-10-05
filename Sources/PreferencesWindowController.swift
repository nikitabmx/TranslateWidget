import Cocoa

/// Preferences: global hotkeys, the translator, the LLM, and per-service API keys.
final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    private let translator = TranslationService()

    private var openRecorder: ShortcutRecorderView?
    private var screenshotRecorder: ShortcutRecorderView?
    private var translationPopup: NSPopUpButton!
    private var llmPopup: NSPopUpButton!

    private var keyServicePopup: NSPopUpButton!
    private var apiKeyField: NSTextField!
    private var saveButton: NSButton!
    private var copyButton: NSButton!
    private var keyStatusLabel: NSTextField!
    private var keyErrorCopyButton: NSButton!
    private var lastKeyError = ""
    private var isEditingKey = false

    convenience init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 590),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        buildUI()
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }

        // --- Hotkeys ---
        let hotkeyTitle = sectionTitle("Shortcuts")
        let (openRow, openRecorder) = hotkeyRow(label: "Open (picks up selected text)",
                                                manager: .shared, reset: #selector(resetHotKey))
        let (screenshotRow, screenshotRecorder) = hotkeyRow(label: "Screenshot and translate",
                                                            manager: .screenshot, reset: #selector(resetScreenshotHotKey))
        self.openRecorder = openRecorder
        self.screenshotRecorder = screenshotRecorder

        let hotkeyHint = hint("Click a field and press a shortcut (at least one modifier: ⌘ ⌥ ⌃ ⇧). Escape to cancel.")

        // --- Translation ---
        let translationTitle = sectionTitle("Translation")
        translationPopup = NSPopUpButton()
        for provider in TranslationProvider.allCases {
            translationPopup.addItem(withTitle: provider.title)
        }
        translationPopup.target = self
        translationPopup.action = #selector(translationChanged)

        let translationHint = hint("Who translates your text. Options without a saved API key are disabled — add the key below.")

        // --- LLM (dictation cleanup + spelling fix) ---
        let llmTitle = sectionTitle("LLM — dictation & spelling")
        llmPopup = NSPopUpButton()
        for provider in TranslationProvider.llmProviders {
            llmPopup.addItem(withTitle: provider.title)
        }
        llmPopup.target = self
        llmPopup.action = #selector(llmChanged)

        let llmHint = hint("Speech recognition runs natively on macOS; the selected LLM polishes the recognized text and powers the ✨ spelling/grammar fix.")

        // --- API keys ---
        let keysTitle = sectionTitle("API keys")
        keyServicePopup = NSPopUpButton()
        for provider in TranslationProvider.keyedProviders {
            keyServicePopup.addItem(withTitle: provider.title)
        }
        keyServicePopup.target = self
        keyServicePopup.action = #selector(keyServiceChanged)

        apiKeyField = NSTextField()
        apiKeyField.delegate = self
        apiKeyField.translatesAutoresizingMaskIntoConstraints = false
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true

        saveButton = NSButton(title: "Save", target: self, action: #selector(saveOrEditKey))
        saveButton.bezelStyle = .rounded
        saveButton.keyEquivalent = "\r"

        copyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy") ?? NSImage(),
                              target: self, action: #selector(copyKey))
        copyButton.bezelStyle = .texturedRounded
        copyButton.imagePosition = .imageOnly
        copyButton.toolTip = "Copy the saved key"
        copyButton.setAccessibilityLabel("Copy API key")

        let keyRow = NSStackView(views: [apiKeyField, saveButton, copyButton])
        keyRow.orientation = .horizontal
        keyRow.spacing = 8

        keyStatusLabel = NSTextField(labelWithString: "")
        keyStatusLabel.font = .systemFont(ofSize: 11)
        keyStatusLabel.textColor = .secondaryLabelColor

        // Copy button next to a validation error, for debugging.
        keyErrorCopyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy error") ?? NSImage(),
                                      target: self, action: #selector(copyKeyError))
        keyErrorCopyButton.isBordered = false
        keyErrorCopyButton.imagePosition = .imageOnly
        keyErrorCopyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        keyErrorCopyButton.contentTintColor = .secondaryLabelColor
        keyErrorCopyButton.toolTip = "Copy error message"
        keyErrorCopyButton.setAccessibilityLabel("Copy error message")
        keyErrorCopyButton.isHidden = true

        let keyStatusRow = NSStackView(views: [keyStatusLabel, keyErrorCopyButton])
        keyStatusRow.orientation = .horizontal
        keyStatusRow.spacing = 6
        keyStatusRow.alignment = .centerY

        let keysHint = hint("Keys are stored locally per service. Press Save to validate; the saved key is then hidden — use the copy button to retrieve it.")

        let stack = NSStackView(views: [
            hotkeyTitle, openRow, screenshotRow, hotkeyHint,
            separator(),
            translationTitle, translationPopup, translationHint,
            separator(),
            llmTitle, llmPopup, llmHint,
            separator(),
            keysTitle, keyServicePopup, keyRow, keyStatusRow, keysHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(16, after: hotkeyHint)
        stack.setCustomSpacing(16, after: translationHint)
        stack.setCustomSpacing(16, after: llmHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -24),
        ])

        refreshProviderPopups()
        keyServicePopup.selectItem(at: 0)
        loadKeyState()
    }

    // MARK: - Small builders

    private func sectionTitle(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        return label
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: 11)
        return label
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return box
    }

    // MARK: - Hotkey

    /// A "label  [shortcut]  Reset (default)" row for one hotkey.
    private func hotkeyRow(label: String, manager: HotKeyManager, reset: Selector) -> (NSStackView, ShortcutRecorderView) {
        let title = NSTextField(labelWithString: label)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let recorder = ShortcutRecorderView(manager: manager)
        recorder.onChange = { keyCode, modifiers in
            manager.update(keyCode: keyCode, modifiers: modifiers)
        }

        let resetButton = NSButton(title: "Reset (\(manager.defaultDisplayString))", target: self, action: reset)
        resetButton.bezelStyle = .rounded

        let row = NSStackView(views: [title, recorder, resetButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        return (row, recorder)
    }

    @objc private func resetHotKey() {
        HotKeyManager.shared.resetToDefault()
        openRecorder?.refresh()
    }

    @objc private func resetScreenshotHotKey() {
        HotKeyManager.screenshot.resetToDefault()
        screenshotRecorder?.refresh()
    }

    // MARK: - Provider selection

    @objc private func translationChanged() {
        let index = translationPopup.indexOfSelectedItem
        guard TranslationProvider.allCases.indices.contains(index) else { return }
        let provider = TranslationProvider.allCases[index]
        guard AppSettings.hasKey(for: provider) else { refreshProviderPopups(); return }
        AppSettings.translationProvider = provider
    }

    @objc private func llmChanged() {
        let index = llmPopup.indexOfSelectedItem
        let providers = TranslationProvider.llmProviders
        guard providers.indices.contains(index) else { return }
        let provider = providers[index]
        guard AppSettings.hasKey(for: provider) else { refreshProviderPopups(); return }
        AppSettings.llmProvider = provider
    }

    /// Reflects which providers are usable (have keys) and restores selections.
    private func refreshProviderPopups() {
        for (i, provider) in TranslationProvider.allCases.enumerated() {
            translationPopup.item(at: i)?.isEnabled = AppSettings.hasKey(for: provider)
        }
        if let index = TranslationProvider.allCases.firstIndex(of: AppSettings.translationProvider) {
            translationPopup.selectItem(at: index)
        }

        for (i, provider) in TranslationProvider.llmProviders.enumerated() {
            llmPopup.item(at: i)?.isEnabled = AppSettings.hasKey(for: provider)
        }
        if let index = TranslationProvider.llmProviders.firstIndex(of: AppSettings.llmProvider) {
            llmPopup.selectItem(at: index)
        }
    }

    // MARK: - API keys

    private var selectedKeyService: TranslationProvider {
        let providers = TranslationProvider.keyedProviders
        let index = keyServicePopup.indexOfSelectedItem
        return providers.indices.contains(index) ? providers[index] : .googleCloud
    }

    @objc private func keyServiceChanged() { loadKeyState() }

    /// Shows the saved (masked) or editable state for the selected service.
    private func loadKeyState() {
        let service = selectedKeyService
        if AppSettings.apiKey(for: service).isEmpty {
            beginEditingKey(clearOnly: true)
        } else {
            showSavedKeyState()
        }
    }

    private func showSavedKeyState() {
        isEditingKey = false
        apiKeyField.isEditable = false
        apiKeyField.isSelectable = false
        apiKeyField.stringValue = String(repeating: "•", count: 12)
        saveButton.title = "Edit"
        saveButton.isEnabled = true
        copyButton.isHidden = false
        keyErrorCopyButton.isHidden = true
        keyStatusLabel.textColor = .systemGreen
        keyStatusLabel.stringValue = "✓ Saved"
    }

    private func beginEditingKey(clearOnly: Bool) {
        isEditingKey = true
        apiKeyField.isEditable = true
        apiKeyField.isSelectable = true
        apiKeyField.stringValue = ""
        apiKeyField.placeholderString = "Paste \(selectedKeyService.title) API key"
        saveButton.title = "Save"
        saveButton.isEnabled = false
        copyButton.isHidden = true
        keyErrorCopyButton.isHidden = true
        if !clearOnly { window?.makeFirstResponder(apiKeyField) }
        keyStatusLabel.stringValue = ""
    }

    @objc private func saveOrEditKey() {
        if isEditingKey {
            validateAndSaveKey()
        } else {
            beginEditingKey(clearOnly: false)
        }
    }

    private func validateAndSaveKey() {
        let service = selectedKeyService
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }

        saveButton.isEnabled = false
        keyErrorCopyButton.isHidden = true
        keyStatusLabel.textColor = .secondaryLabelColor
        keyStatusLabel.stringValue = "Validating…"

        Task { @MainActor in
            do {
                try await translator.validate(provider: service, key: key)
                AppSettings.setAPIKey(key, for: service)
                showSavedKeyState()
                keyStatusLabel.textColor = .systemGreen
                keyStatusLabel.stringValue = "✓ Saved & valid"
                refreshProviderPopups()
            } catch {
                saveButton.isEnabled = true
                keyStatusLabel.textColor = .systemRed
                let (display, details) = TranslatePanelController.describe(error)
                lastKeyError = details // full server response, for the copy button
                keyStatusLabel.stringValue = "✗ \(display)"
                keyErrorCopyButton.isHidden = false
            }
        }
    }

    @objc private func copyKeyError() {
        guard !lastKeyError.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastKeyError, forType: .string)
    }

    @objc private func copyKey() {
        let key = AppSettings.apiKey(for: selectedKeyService)
        guard !key.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        keyErrorCopyButton.isHidden = true
        keyStatusLabel.textColor = .secondaryLabelColor
        keyStatusLabel.stringValue = "Copied to clipboard"
    }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextField) === apiKeyField, isEditingKey else { return }
        let typed = !apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        saveButton.isEnabled = typed
        keyStatusLabel.stringValue = ""
        keyErrorCopyButton.isHidden = true
    }
}
