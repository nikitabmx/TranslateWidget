import Cocoa
import Carbon.HIToolbox

/// An image attached to the input, and where its recognized text sits there.
private final class ImageAttachment {
    let image: NSImage
    let chip: ImageChipView
    var range: NSRange? // nil while the text is still being recognized

    init(image: NSImage) {
        self.image = image
        chip = ImageChipView(image: image)
    }
}

/// A borderless panel that may still become key so the text view gets input.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// A Claude quick-entry–style bar: white rounded card with a soft shadow; a mic
/// on the left, a single input, "Source ⌄ ⇄ Target ⌄", then the fix manner and a
/// small black sparkles button. Translation runs live as you type and is the
/// only thing the result area shows; the sparkles button rewrites the input
/// itself in the chosen manner (captioned under it, ⌘Z undoes it).
/// Opens with an iOS-like spring over a lightly dimmed screen.
final class TranslatePanelController: NSObject, NSTextViewDelegate {
    var onOpenPreferences: (() -> Void)?

    private let service = TranslationService()
    private let dictation = DictationManager()

    // Layout metrics.
    private let cardWidth: CGFloat = 760
    private let margin: CGFloat = 44          // transparent room around the card for its shadow
    private let cornerRadius: CGFloat = 22
    private let hPad: CGFloat = 14
    private let vPad: CGFloat = 15
    private let inputMinHeight: CGFloat = 30
    private let inputMaxHeight: CGFloat = 150
    private let outputMinHeight: CGFloat = 30
    private let outputMaxHeight: CGFloat = 240
    private let sectionGap: CGFloat = 12       // input → separator
    private let outputGap: CGFloat = 8         // separator → result
    private let footerGap: CGFloat = 2         // result → status line
    private let footerHeight: CGFloat = 20
    private let expandedBottomPad: CGFloat = 12
    private let textColumn: CGFloat = 40       // mic + gap: the result lines up with the input text
    private let inputCaptionHeight: CGFloat = 22 // "Fixed · … ⧉" / "Text from image" line under the input

    private var panel: KeyablePanel!
    private var dimWindow: DimWindow!
    private var card: ShadowCardView!
    private var body: NSView { card.content }
    private var micButton: HoverButton!
    private var inputView: PlaceholderTextView!
    private var inputScroll: NSScrollView!
    private var waveform: WaveformView!
    private var sourceButton: MenuButton!
    private var swapButton: HoverButton!
    private var targetButton: MenuButton!
    private var mannerButton: MenuButton!
    private var magicButton: GlyphButton!
    private var outputContainer: NSView!
    private var outputView: PlaceholderTextView!
    private var outputScroll: NSScrollView!
    private var skeleton: SkeletonView!
    private var inputSkeleton: SkeletonView!
    private var inputCaption: NSTextField!
    private var inputCaptionRow: NSStackView!
    private var inputCopyButton: HoverButton!
    private var inputErrorCopyButton: NSButton!
    private var inputSettingsButton: HoverButton! // "Open Settings" for permission hints
    private var settingsPaneURL: URL?
    private var copyButton: HoverButton!
    private var statusLabel: NSTextField!
    private var errorCopyButton: NSButton!
    private var lastErrorMessage = ""
    private var dictationBaseText = ""
    private var dictationCancelled = false
    private var keyMonitor: Any?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    // True while the mic/speech permission dialog is up, so an "outside click"
    // on that system dialog doesn't dismiss the panel mid-request.
    private var awaitingAuth = false
    // After an outside click closes the panel, briefly swallow the re-open that a
    // click on the menu-bar item would otherwise trigger on mouse-up.
    private var suppressReopen = false

    private var inputHeightC: NSLayoutConstraint!
    private var outputTopGapC: NSLayoutConstraint!
    private var outputHeightC: NSLayoutConstraint!
    private var outputBottomC: NSLayoutConstraint!

    private var pendingTranslate: DispatchWorkItem?
    private var requestToken = 0
    private var lastDetected: String? { didSet { updateSwapState() } }

    // Loading skeleton.
    private var isLoading = false
    private var skeletonShown = false
    private var skeletonHeight: CGFloat = 0
    private var skeletonDelay: DispatchWorkItem?

    private enum PanelState { case shown, hidden }
    private var desiredState: PanelState = .hidden
    private var pendingReset = false // hidden since the last open → clear before showing again

    // Fixing and image recognition both rewrite the input; while one runs the
    // input is locked ("busy") and shimmers.
    private var isInputBusy = false
    private var applyingEdit = false // our own edit — keeps the caption up
    private var inputToken = 0

    // Image drag highlight + hotkey selection pickup.
    private var dropOverlay: DropOverlayView!
    private var dropHoverOff: DispatchWorkItem?
    private var readingSelection = false
    private var capturing = false // screenshot mode: selecting a piece of the screen

    // Attached images (pasted, dropped or screenshotted), shown as chips before
    // the input text. Each chip owns the text recognized from its image.
    private var chipsStack: NSStackView!
    private var inputLeadingC: NSLayoutConstraint!
    private var attachments: [ImageAttachment] = []
    private var previewPopover: NSPopover?

    // Fix manner: 1 = light (errors + punctuation), 2 = balanced, 3 = strict formal.
    private lazy var fixLevel: Int = {
        let saved = UserDefaults.standard.object(forKey: "fixLevel") as? Int ?? 1
        return min(max(saved, 1), 3)
    }()
    private static let manners: [(title: String, detail: String)] = [
        ("Light", "errors and punctuation"),
        ("Balanced", "clearer wording"),
        ("Formal", "strict business style"),
    ]

    // Languages offered in the pickers (plus the current keyboard language).
    private let languageCodes = ["ru", "en", "sr", "sl"]
    private var availableCodes: [String] = []

    /// Source: "auto" (Detect) or a concrete code. Reset to the current keyboard
    /// layout's language on every open; the saved value only seeds the fallback.
    private lazy var sourceSelection: String = UserDefaults.standard.string(forKey: "sourceLang") ?? "auto"
    /// Target: a concrete code, persisted across opens.
    private lazy var targetSelection: String = UserDefaults.standard.string(forKey: "targetLang") ?? "en"

    override init() {
        super.init()
        build()
    }

    deinit {
        dictation.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
    }

    func toggle() {
        // The same click that dismissed the panel by landing on the menu-bar item
        // would otherwise re-open it on mouse-up — swallow that one toggle.
        if suppressReopen { suppressReopen = false; return }
        desiredState == .shown ? hide() : show()
    }

    /// The hotkey: opens the widget with whatever text is selected in the
    /// frontmost app already in the input (and translating); closes it if open.
    func toggleWithSelection() {
        if suppressReopen { suppressReopen = false; return }
        guard desiredState != .shown else { hide(); return }
        guard !readingSelection else { return }
        readingSelection = true
        SelectionReader.read { [weak self] result in
            guard let self else { return }
            self.readingSelection = false
            guard self.desiredState != .shown else { return }
            self.resetIfPending() // clear the last session before filling in this one
            switch result {
            case .text(let text):
                self.takeSelection(text)
                self.show(sourceFromKeyboard: false)
                self.translateNow()
            case .needsPermission:
                self.show()
                self.showInputError(message: "Needs Accessibility access",
                                    settingsPane: "Privacy_Accessibility")
            case .nothing:
                self.show()
            }
        }
    }

    /// Puts picked-up text in the input, replacing whatever was there. It can be
    /// in any language, so the source switches to Detect for this session.
    private func takeSelection(_ text: String) {
        sourceSelection = "auto"
        refreshLanguageMenus()
        if isInputBusy { // a fix / recognition would overwrite it — drop that
            inputToken += 1
            setInputBusy(false)
        }
        clearInputCaption()
        detachAllImages() // their text is being replaced
        lastDetected = nil
        inputView.string = text
        inputView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        inputView.needsDisplay = true
        outputView.string = "" // the old translation is about something else
    }

    /// Show the panel (and focus it) without ever toggling it closed. Used when the
    /// app is launched or its icon is clicked — the app is otherwise invisible
    /// (menu-bar only), so a launch that did nothing visible feels broken.
    func open() {
        suppressReopen = false
        if desiredState == .shown {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(inputView)
        } else {
            show()
        }
    }

    // MARK: - Build

    private func build() {
        panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: cardWidth + margin * 2, height: 60 + margin * 2),
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1) // above the dimmer
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the card draws its own softer shadow
        panel.isMovableByWindowBackground = false
        panel.appearance = NSAppearance(named: .aqua) // the card is always white
        // NSPanel defaults this to true, which makes the panel vanish whenever the
        // app deactivates — e.g. when the macOS permission dialog appears.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.hide() }

        // The dimmed backdrop: a click closes the widget, a drag screenshots a piece of the screen.
        dimWindow = DimWindow()
        dimWindow.selectionView.onClick = { [weak self] in self?.backdropClicked() }
        dimWindow.selectionView.onSelect = { [weak self] rect in self?.captureScreen(rect) }

        let root = ImageDropView() // images dropped anywhere on the panel get recognized
        root.wantsLayer = true
        root.onImage = { [weak self] image in self?.attachImage(image) }
        root.onHover = { [weak self] hovering in self?.setDropHighlight(hovering) }
        panel.contentView = root

        card = ShadowCardView(cornerRadius: cornerRadius)
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: margin),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -margin),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: margin),
            card.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -margin),
        ])

        // Left: mic — where Claude's logo sits. The waveform flows out of it.
        micButton = HoverButton()
        micButton.imagePosition = .imageOnly
        micButton.target = self
        micButton.action = #selector(toggleDictation)
        setMicAppearance(active: false)
        body.addSubview(micButton)

        // Attached-image chips sit between the mic and the text.
        chipsStack = NSStackView()
        chipsStack.orientation = .horizontal
        chipsStack.alignment = .centerY
        chipsStack.spacing = 6
        chipsStack.setHuggingPriority(.required, for: .horizontal)
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(chipsStack)

        inputScroll = makeTextArea(placeholder: "Enter text to translate…", editable: true)
        inputView.delegate = self
        inputView.onImage = { [weak self] image in self?.attachImage(image) }
        inputView.onImageDragHover = { [weak self] hovering in self?.setDropHighlight(hovering) }
        inputView.setAccessibilityLabel("Text to translate")
        body.addSubview(inputScroll)

        // Right: Source ⌄  ⇄  Target ⌄  │  Manner ⌄  [wand]
        sourceButton = MenuButton()
        sourceButton.toolTip = "Translate from"
        sourceButton.setAccessibilityLabel("Source language")
        sourceButton.onSelect = { [weak self] code in self?.setSource(code) }

        swapButton = HoverButton()
        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Swap languages")
        swapButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        swapButton.imagePosition = .imageOnly
        swapButton.contentTintColor = NSColor(white: 0.40, alpha: 1)
        swapButton.target = self
        swapButton.action = #selector(swapLanguages)
        swapButton.toolTip = "Swap languages"
        swapButton.setAccessibilityLabel("Swap languages")

        targetButton = MenuButton()
        targetButton.toolTip = "Translate to"
        targetButton.setAccessibilityLabel("Target language")
        targetButton.onSelect = { [weak self] code in self?.setTarget(code) }

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        mannerButton = MenuButton()
        mannerButton.items = Self.manners.enumerated().map { index, manner in
            MenuButton.Item(title: manner.title, value: String(index + 1), detail: manner.detail)
        }
        mannerButton.selectedValue = String(fixLevel)
        mannerButton.toolTip = "How the wand fixes your text"
        mannerButton.setAccessibilityLabel("Fix manner")
        mannerButton.onSelect = { [weak self] value in self?.setLevel(Int(value) ?? 1) }

        magicButton = GlyphButton(symbols: ["sparkles"], pointSize: 14)
        magicButton.toolTip = "Fix spelling and style of your text"
        magicButton.setAccessibilityLabel("Fix text")
        magicButton.onPress = { [weak self] in self?.fixInput() }

        let rightStack = NSStackView(views: [sourceButton, swapButton, targetButton, divider, mannerButton, magicButton])
        rightStack.orientation = .horizontal
        rightStack.alignment = .centerY
        rightStack.spacing = 0
        rightStack.setCustomSpacing(10, after: targetButton)
        rightStack.setCustomSpacing(10, after: divider)
        rightStack.setCustomSpacing(6, after: mannerButton)
        rightStack.setHuggingPriority(.required, for: .horizontal)
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(rightStack)

        // Live waveform — overlays the input row while dictating.
        waveform = WaveformView()
        waveform.color = .systemRed
        waveform.alignment = .leading
        waveform.isHidden = true
        waveform.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(waveform)

        // While the input is being fixed, its lines turn into a skeleton.
        inputSkeleton = SkeletonView()
        inputSkeleton.isHidden = true
        inputSkeleton.alphaValue = 0
        body.addSubview(inputSkeleton)

        // "Fixed · Formal · ⌘Z to undo" / "Text from image · …" (or an error) right under the input.
        inputCaption = NSTextField(labelWithString: "")
        inputCaption.font = .systemFont(ofSize: 12)
        inputCaption.textColor = .secondaryLabelColor
        inputCaption.lineBreakMode = .byTruncatingTail
        inputCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        inputErrorCopyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy error") ?? NSImage(),
                                      target: self, action: #selector(copyError))
        inputErrorCopyButton.isBordered = false
        inputErrorCopyButton.imagePosition = .imageOnly
        inputErrorCopyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        inputErrorCopyButton.contentTintColor = .secondaryLabelColor
        inputErrorCopyButton.toolTip = "Copy error message"
        inputErrorCopyButton.setAccessibilityLabel("Copy error message")
        inputErrorCopyButton.isHidden = true
        inputErrorCopyButton.setContentHuggingPriority(.required, for: .horizontal)

        // Copies the fixed text; shown only while the input holds a fix.
        inputCopyButton = makeCopyButton(pointSize: 13, action: #selector(copyInput))
        inputCopyButton.setAccessibilityLabel("Copy fixed text")
        inputCopyButton.isHidden = true

        inputSettingsButton = HoverButton()
        inputSettingsButton.title = "Open Settings"
        inputSettingsButton.font = .systemFont(ofSize: 12, weight: .medium)
        inputSettingsButton.contentTintColor = .controlAccentColor
        inputSettingsButton.layer?.cornerRadius = 6
        inputSettingsButton.target = self
        inputSettingsButton.action = #selector(openSettingsPane)
        inputSettingsButton.isHidden = true

        inputCaptionRow = NSStackView(views: [inputCaption, inputCopyButton, inputErrorCopyButton, inputSettingsButton])
        inputCaptionRow.orientation = .horizontal
        inputCaptionRow.spacing = 6
        inputCaptionRow.alignment = .centerY
        inputCaptionRow.isHidden = true
        inputCaptionRow.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(inputCaptionRow)

        // Result area (expands below the input).
        outputContainer = NSView()
        outputContainer.translatesAutoresizingMaskIntoConstraints = false
        outputContainer.alphaValue = 0
        body.addSubview(outputContainer)

        let separator = NSView()
        separator.wantsLayer = true
        separator.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.08).cgColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        outputContainer.addSubview(separator)

        outputScroll = makeTextArea(placeholder: "Translation", editable: false)
        outputView.setAccessibilityLabel("Translation")
        outputContainer.addSubview(outputScroll)

        skeleton = SkeletonView()
        skeleton.isHidden = true
        skeleton.alphaValue = 0
        outputContainer.addSubview(skeleton)

        // Copy — icon only, in its own column right of the result (not over the
        // text, so it never gets the text cursor), level with the first line.
        copyButton = makeCopyButton(pointSize: 15, action: #selector(copyOutput))
        copyButton.setAccessibilityLabel("Copy translation")
        copyButton.isHidden = true
        outputContainer.addSubview(copyButton)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Copy button shown next to an error message, for easy debugging.
        errorCopyButton = NSButton(image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy error") ?? NSImage(),
                                   target: self, action: #selector(copyError))
        errorCopyButton.isBordered = false
        errorCopyButton.imagePosition = .imageOnly
        errorCopyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        errorCopyButton.contentTintColor = .secondaryLabelColor
        errorCopyButton.toolTip = "Copy error message"
        errorCopyButton.setAccessibilityLabel("Copy error message")
        errorCopyButton.isHidden = true
        errorCopyButton.setContentHuggingPriority(.required, for: .horizontal)

        let statusRow = NSStackView(views: [statusLabel, errorCopyButton])
        statusRow.orientation = .horizontal
        statusRow.spacing = 6
        statusRow.alignment = .centerY
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        outputContainer.addSubview(statusRow)

        // Drop highlight — on top of everything in the card.
        dropOverlay = DropOverlayView(cornerRadius: cornerRadius)
        dropOverlay.alphaValue = 0
        dropOverlay.isHidden = true
        body.addSubview(dropOverlay)

        // Variable constraints.
        inputHeightC = inputScroll.heightAnchor.constraint(equalToConstant: inputMinHeight)
        outputTopGapC = outputContainer.topAnchor.constraint(equalTo: inputScroll.bottomAnchor, constant: 0)
        outputHeightC = outputContainer.heightAnchor.constraint(equalToConstant: 0)
        outputBottomC = outputScroll.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor, constant: 0)
        inputLeadingC = inputScroll.leadingAnchor.constraint(equalTo: chipsStack.trailingAnchor, constant: 0) // 8 with chips

        // Controls center on the first input line (30pt tall), so they stay put
        // while the input grows downward.
        let firstLine = inputMinHeight / 2

        NSLayoutConstraint.activate([
            micButton.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: hPad),
            micButton.centerYAnchor.constraint(equalTo: inputScroll.topAnchor, constant: firstLine),
            micButton.widthAnchor.constraint(equalToConstant: 32),
            micButton.heightAnchor.constraint(equalToConstant: 32),

            inputScroll.topAnchor.constraint(equalTo: body.topAnchor, constant: vPad),
            chipsStack.leadingAnchor.constraint(equalTo: micButton.trailingAnchor, constant: 8),
            chipsStack.centerYAnchor.constraint(equalTo: inputScroll.topAnchor, constant: firstLine),
            inputLeadingC,
            inputScroll.trailingAnchor.constraint(equalTo: rightStack.leadingAnchor, constant: -10),
            inputHeightC,

            rightStack.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -hPad),
            rightStack.centerYAnchor.constraint(equalTo: inputScroll.topAnchor, constant: firstLine),
            swapButton.widthAnchor.constraint(equalToConstant: 28),
            swapButton.heightAnchor.constraint(equalToConstant: 28),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 18),

            waveform.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor),
            waveform.trailingAnchor.constraint(equalTo: inputScroll.trailingAnchor),
            waveform.topAnchor.constraint(equalTo: inputScroll.topAnchor),
            waveform.bottomAnchor.constraint(equalTo: inputScroll.bottomAnchor),

            inputSkeleton.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor),
            inputSkeleton.trailingAnchor.constraint(equalTo: inputScroll.trailingAnchor),
            inputSkeleton.topAnchor.constraint(equalTo: inputScroll.topAnchor),
            inputSkeleton.bottomAnchor.constraint(equalTo: inputScroll.bottomAnchor),

            inputCaptionRow.leadingAnchor.constraint(equalTo: inputScroll.leadingAnchor, constant: 2),
            inputCaptionRow.trailingAnchor.constraint(lessThanOrEqualTo: inputScroll.trailingAnchor),
            inputCaptionRow.topAnchor.constraint(equalTo: inputScroll.bottomAnchor),
            inputCaptionRow.heightAnchor.constraint(equalToConstant: inputCaptionHeight),
            inputCopyButton.widthAnchor.constraint(equalToConstant: 24),
            inputCopyButton.heightAnchor.constraint(equalToConstant: 22),
            inputSettingsButton.widthAnchor.constraint(equalToConstant: 96),
            inputSettingsButton.heightAnchor.constraint(equalToConstant: 20),
            inputErrorCopyButton.widthAnchor.constraint(equalToConstant: 18),
            inputErrorCopyButton.heightAnchor.constraint(equalToConstant: 18),

            outputTopGapC,
            outputContainer.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: hPad),
            outputContainer.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -hPad),
            outputHeightC,

            separator.topAnchor.constraint(equalTo: outputContainer.topAnchor),
            separator.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            outputScroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: outputGap),
            outputScroll.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor, constant: textColumn),
            outputScroll.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),
            outputBottomC,

            skeleton.leadingAnchor.constraint(equalTo: outputScroll.leadingAnchor),
            skeleton.trailingAnchor.constraint(equalTo: outputScroll.trailingAnchor),
            skeleton.topAnchor.constraint(equalTo: outputScroll.topAnchor),
            skeleton.bottomAnchor.constraint(equalTo: outputScroll.bottomAnchor),

            // Same column as the wand above it; centered on the first result line.
            copyButton.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: outputScroll.topAnchor, constant: 15),
            copyButton.widthAnchor.constraint(equalToConstant: 28),
            copyButton.heightAnchor.constraint(equalToConstant: 28),

            // Status line (Detected… / Fixed… / errors) — only takes room with text.
            statusRow.leadingAnchor.constraint(equalTo: outputScroll.leadingAnchor, constant: 2),
            statusRow.trailingAnchor.constraint(lessThanOrEqualTo: outputContainer.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: footerHeight),
            errorCopyButton.widthAnchor.constraint(equalToConstant: 18),
            errorCopyButton.heightAnchor.constraint(equalToConstant: 18),

            dropOverlay.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            dropOverlay.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            dropOverlay.topAnchor.constraint(equalTo: body.topAnchor),
            dropOverlay.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])

        refreshLanguageMenus()
        installKeyMonitor()
        installOutsideClickMonitors()
    }

    private func makeTextArea(placeholder: String, editable: Bool) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.verticalScrollElasticity = .allowed

        let textView = PlaceholderTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.placeholder = placeholder
        textView.isEditable = editable
        textView.isSelectable = true
        textView.allowsUndo = editable // ⌘Z also takes back a fix
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 18)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        scroll.documentView = textView

        if editable { inputView = textView } else { outputView = textView }
        return scroll
    }

    // MARK: - Languages

    /// Rebuilds both language menus from the known languages plus whatever the
    /// current selections / keyboard layout need.
    private func refreshLanguageMenus() {
        var codes = languageCodes
        for code in [Self.currentInputLanguageCode(), targetSelection, sourceSelection]
            where code != "auto" && !codes.contains(code) {
            codes.append(code)
        }
        availableCodes = codes
        let languages = codes.map { MenuButton.Item(title: LanguagePair.displayName($0), value: $0) }
        sourceButton.items = [MenuButton.Item(title: "Detect", value: "auto")] + languages
        targetButton.items = languages
        sourceButton.selectedValue = sourceSelection
        targetButton.selectedValue = targetSelection
        updateSwapState()
    }

    /// The source as a concrete language (the detected one when on "Detect").
    private var concreteSource: String? {
        sourceSelection == "auto" ? lastDetected : sourceSelection
    }

    private func otherLanguage(than code: String) -> String {
        availableCodes.first { $0 != code } ?? "en"
    }

    /// Picking the target's language as the source swaps the pair, so the two
    /// never end up the same.
    private func setSource(_ code: String) {
        guard code != sourceSelection else { return }
        let flips = code != "auto" && code == targetSelection
        let cleanSwap = flips && sourceSelection != "auto" // target takes the old source
        let apply = { [self] in
            if flips {
                let previous = concreteSource ?? otherLanguage(than: code)
                targetSelection = previous == code ? otherLanguage(than: code) : previous
            }
            sourceSelection = code
            if code != "auto" { lastDetected = nil }
            refreshLanguageMenus()
        }
        cleanSwap ? animateLanguageSwap(apply) : apply()
        if flips { moveResultIntoInput() }
        languagesChanged()
    }

    private func setTarget(_ code: String) {
        guard code != targetSelection else { return }
        let flips = code == sourceSelection
        let apply = { [self] in
            if flips { sourceSelection = targetSelection } // swap
            targetSelection = code
            refreshLanguageMenus()
        }
        flips ? animateLanguageSwap(apply) : apply()
        if flips { moveResultIntoInput() }
        languagesChanged()
    }

    /// ⇄ — swap source and target; the current translation becomes the new input.
    @objc private func swapLanguages() {
        guard let source = concreteSource, source != targetSelection else { return }
        animateLanguageSwap { [self] in
            let newSource = targetSelection
            targetSelection = source
            sourceSelection = newSource
            lastDetected = nil
            refreshLanguageMenus()
        }
        moveResultIntoInput()
        languagesChanged()
    }

    /// After source and target trade places, the translation is in the new
    /// source language — it becomes the input and gets translated back.
    private func moveResultIntoInput() {
        let translated = outputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return }
        if isInputBusy { // the input is about to change under a fix / recognition — drop it
            inputToken += 1
            setInputBusy(false)
        }
        clearInputCaption()
        detachAllImages() // the input is replaced wholesale
        inputView.string = translated
        inputView.setSelectedRange(NSRange(location: (translated as NSString).length, length: 0))
        inputView.needsDisplay = true
    }

    /// Runs a change that flips source and target, and animates it: the two
    /// labels slide straight into each other's slots.
    private func animateLanguageSwap(_ change: () -> Void) {
        guard panel.isVisible,
              let sourceImage = sourceButton.snapshotImage(),
              let targetImage = targetButton.snapshotImage() else {
            change()
            return
        }
        let oldSource = sourceButton.convert(sourceButton.bounds, to: body)
        let oldTarget = targetButton.convert(targetButton.bounds, to: body)
        change()
        body.layoutSubtreeIfNeeded()
        let newSource = sourceButton.convert(sourceButton.bounds, to: body)
        let newTarget = targetButton.convert(targetButton.bounds, to: body)

        // The old source label lands in the target slot and vice versa — which is
        // exactly what the real buttons show once the flight is over.
        let flights: [(image: NSImage, from: NSRect, to: NSRect)] = [
            (sourceImage, oldSource, newTarget),
            (targetImage, oldTarget, newSource),
        ]
        sourceButton.alphaValue = 0
        targetButton.alphaValue = 0
        var flyers: [NSImageView] = []

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            flyers.forEach { $0.removeFromSuperview() }
            self?.sourceButton.alphaValue = 1
            self?.targetButton.alphaValue = 1
        }
        for flight in flights {
            let flyer = NSImageView(frame: flight.to) // model sits at the destination
            flyer.image = flight.image
            flyer.imageScaling = .scaleNone
            flyer.autoresizingMask = [.minYMargin] // stay with the top row if the card grows
            flyer.wantsLayer = true
            body.addSubview(flyer)
            flyers.append(flyer)
            guard let layer = flyer.layer else { continue }

            let slide = CABasicAnimation(keyPath: "position.x")
            slide.fromValue = layer.position.x - (flight.to.minX - flight.from.minX)
            slide.toValue = layer.position.x
            slide.duration = 0.25
            slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(slide, forKey: "slide")
        }
        CATransaction.commit()
    }

    private func languagesChanged() {
        UserDefaults.standard.set(sourceSelection, forKey: "sourceLang")
        UserDefaults.standard.set(targetSelection, forKey: "targetLang")
        refreshLanguageMenus()
        translateNow()
        relayout(animated: true)
    }

    private func updateSwapState() {
        guard swapButton != nil else { return }
        let source = concreteSource
        swapButton.isEnabled = source != nil && source != targetSelection
        swapButton.alphaValue = swapButton.isEnabled ? 1 : 0.35
    }

    /// On open, the source follows the current keyboard layout — you type in the
    /// layout's language (no live tracking). If the saved target is that same
    /// language, fall back to what we translated from last time.
    private func adoptKeyboardLanguageAsSource() {
        let current = Self.currentInputLanguageCode()
        let previousSource = sourceSelection
        sourceSelection = current
        lastDetected = nil
        if targetSelection == current {
            targetSelection = previousSource != "auto" && previousSource != current
                ? previousSource
                : otherLanguage(than: current)
        }
        UserDefaults.standard.set(sourceSelection, forKey: "sourceLang")
        UserDefaults.standard.set(targetSelection, forKey: "targetLang")
        refreshLanguageMenus()
    }

    // MARK: - Translate / fix

    func textDidChange(_ notification: Notification) {
        if inputView.string.isEmpty { lastDetected = nil }
        if !applyingEdit { clearInputCaption() } // edited since the fix / recognition
        scheduleTranslate() // live
        relayout(animated: true)
    }

    /// Return translates right away; Shift+Return inserts a literal newline.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === inputView else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shiftHeld = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shiftHeld {
                textView.insertNewlineIgnoringFieldEditor(self)
            } else {
                translateNow()
            }
            return true
        }
        return false
    }

    private var hasInput: Bool {
        !inputView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func scheduleTranslate() {
        pendingTranslate?.cancel()
        // Nothing to show yet → put the skeleton up while we wait out the debounce.
        if hasInput, outputView.string.isEmpty { setLoading(true) }
        let work = DispatchWorkItem { [weak self] in self?.translateNow() }
        pendingTranslate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Translates the input into the result area — the only thing it shows.
    private func translateNow() {
        pendingTranslate?.cancel()
        requestToken += 1 // anything still in flight is now stale
        let token = requestToken
        let text = inputView.string
        guard hasInput else {
            outputView.string = ""
            clearStatus()
            setLoading(false)
            relayout(animated: true)
            return
        }

        let source = sourceSelection
        let target = targetSelection
        setLoading(true)

        Task { @MainActor in
            do {
                let result = try await service.translate(text: text, source: source, target: target)
                guard token == requestToken else { return }
                if source == "auto", let detected = result.detected {
                    lastDetected = detected
                    if detected == target { // it's already in the target language — aim elsewhere
                        targetSelection = alternativeTarget(to: detected)
                        refreshLanguageMenus()
                        translateNow()
                        return
                    }
                    showInfo("Detected: \(LanguagePair.displayName(detected))")
                } else {
                    clearStatus()
                }
                outputView.string = result.translated
                setLoading(false)
                relayout(animated: true)
                announce(result.translated)
            } catch {
                guard token == requestToken else { return }
                setLoading(false)
                showError(error)
                announce(Self.describe(error).display)
            }
        }
    }

    /// Where to translate text that turned out to be in the target language
    /// already: the keyboard layout's language, else the saved target, else
    /// any other one. (Not saved — the next open starts from the saved target.)
    private func alternativeTarget(to detected: String) -> String {
        let keyboard = Self.currentInputLanguageCode()
        if keyboard != detected { return keyboard }
        if let saved = UserDefaults.standard.string(forKey: "targetLang"), saved != detected { return saved }
        return otherLanguage(than: detected)
    }

    /// The sparkles button — the only way to fix: rewrites the input itself in
    /// the chosen manner, then the translation follows the fixed text.
    private func fixInput() {
        guard hasInput, !isInputBusy, !dictation.isRunning else { return }
        let text = inputView.string
        let level = fixLevel
        inputToken += 1
        let token = inputToken
        clearInputCaption()
        setInputBusy(true)
        relayout(animated: true)

        Task { @MainActor in
            do {
                let fixed = try await service.correct(text: text, level: level)
                guard token == inputToken else { return }
                setInputBusy(false)
                applyFix(fixed)
                showInputCaption("Fixed · \(Self.manners[level - 1].title) · ⌘Z to undo")
                announce("Text fixed")
                translateNow()
            } catch {
                guard token == inputToken else { return }
                setInputBusy(false)
                showInputError(error)
                announce(Self.describe(error).display)
            }
        }
    }

    /// Swaps in the fixed text as one undoable edit.
    private func applyFix(_ fixed: String) {
        let whole = NSRange(location: 0, length: (inputView.string as NSString).length)
        // An image whose text was the whole input keeps owning it once fixed.
        let owner = attachments.count == 1 && attachments[0].range == whole ? attachments[0] : nil
        replaceInput(whole, with: fixed)
        owner?.range = NSRange(location: 0, length: (fixed as NSString).length)
    }

    // MARK: - Images

    /// An image pasted, dropped or screenshotted: attach it as a chip, recognize
    /// its text on-device, insert that at the cursor (like a paste) and
    /// translate right away. The chip owns the text — removing one removes both.
    private func attachImage(_ image: NSImage) {
        guard !isInputBusy, !dictation.isRunning else { return }
        if desiredState != .shown { show() }
        let attachment = ImageAttachment(image: image)
        attachment.chip.onOpen = { [weak self, weak attachment] in
            guard let self, let attachment else { return }
            self.preview(attachment)
        }
        attachment.chip.onRemove = { [weak self, weak attachment] in
            guard let self, let attachment else { return }
            self.remove(attachment)
        }
        attachments.append(attachment)
        chipsStack.addArrangedSubview(attachment.chip)
        refreshChips()

        inputToken += 1
        let token = inputToken
        // Hints for the recognizer: the language being typed, then the pair.
        let languages = [sourceSelection, Self.currentInputLanguageCode(), targetSelection, "en"]
            .filter { $0 != "auto" }
        clearInputCaption()
        setInputBusy(true)
        relayout(animated: true)

        Task { @MainActor in
            do {
                let text = try await TextRecognizer.recognizeText(in: image, preferredLanguages: languages)
                DebugLog.log("ocr: \(text.count) chars")
                guard token == inputToken, attachments.contains(where: { $0 === attachment }) else { return }
                setInputBusy(false)
                let at = inputView.selectedRange()
                replaceInput(at, with: text)
                attachment.range = NSRange(location: at.location, length: (text as NSString).length)
                showInputCaption("Text from image · ⌘Z to undo")
                announce("Text recognized")
                translateNow()
            } catch {
                DebugLog.log("ocr: failed — \(error.localizedDescription)")
                guard token == inputToken else { return }
                setInputBusy(false)
                detach(attachment)
                showInputError(error)
                announce(Self.describe(error).display)
            }
        }
    }

    /// The chip's ✕: the image goes, and so does the text recognized from it.
    private func remove(_ attachment: ImageAttachment) {
        guard attachments.contains(where: { $0 === attachment }) else { return }
        if attachment.range == nil, isInputBusy { // still recognizing — cancel that
            inputToken += 1
            setInputBusy(false)
        }
        detach(attachment)
        clearInputCaption()
        if let range = attachment.range, range.length > 0,
           NSMaxRange(range) <= (inputView.string as NSString).length {
            replaceInput(range, with: "")
            translateNow()
        }
        relayout(animated: true)
    }

    /// Drops the chip only (its text, if any, stays).
    private func detach(_ attachment: ImageAttachment) {
        attachments.removeAll { $0 === attachment }
        attachment.chip.removeFromSuperview()
        if previewPopover?.isShown == true { previewPopover?.close() }
        refreshChips()
    }

    private func detachAllImages() {
        attachments.forEach(detach)
    }

    private func refreshChips() {
        inputLeadingC.constant = attachments.isEmpty ? 0 : 8
    }

    /// Clicking a chip: the image in a popover above it.
    private func preview(_ attachment: ImageAttachment) {
        previewPopover?.close()
        let size = attachment.image.size
        let scale = min(1, 420 / max(size.width, 1), 300 / max(size.height, 1))
        let fitted = NSSize(width: max(size.width * scale, 40), height: max(size.height * scale, 30))
        let imageView = NSImageView(frame: NSRect(x: 8, y: 8, width: fitted.width, height: fitted.height))
        imageView.image = attachment.image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        let container = NSView(frame: NSRect(x: 0, y: 0, width: fitted.width + 16, height: fitted.height + 16))
        container.addSubview(imageView)
        let controller = NSViewController()
        controller.view = container

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .aqua)
        popover.show(relativeTo: attachment.chip.bounds, of: attachment.chip, preferredEdge: .maxY)
        previewPopover = popover
    }

    /// Keeps each image's text range pointing at the same text as the input is
    /// edited (typing, undo, fixes); an image whose text is gone loses its chip.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard textView === inputView, let replacementString, !attachments.isEmpty else { return true }
        let length = (replacementString as NSString).length
        for attachment in attachments {
            guard let tracked = attachment.range else { continue }
            attachment.range = Self.track(tracked, acrossEditOf: range, replacementLength: length)
        }
        DispatchQueue.main.async { [weak self] in // once the edit has landed
            guard let self else { return }
            self.attachments.filter { $0.range?.length == 0 }.forEach(self.detach)
            self.relayout(animated: true)
        }
        return true
    }

    /// Where `tracked` ends up once `edit` is replaced by `length` characters.
    /// Edits inside or overlapping it become part of it; replacing all of it
    /// leaves it empty.
    private static func track(_ tracked: NSRange, acrossEditOf edit: NSRange, replacementLength length: Int) -> NSRange {
        let delta = length - edit.length
        if NSMaxRange(edit) <= tracked.location { // before it (incl. typing right at its start)
            return NSRange(location: tracked.location + delta, length: tracked.length)
        }
        if edit.location >= NSMaxRange(tracked) { return tracked } // after it (incl. right at its end)
        if edit.location <= tracked.location && NSMaxRange(edit) >= NSMaxRange(tracked) {
            return NSRange(location: edit.location, length: 0) // all of it replaced
        }
        let start = min(tracked.location, edit.location)
        let end = max(NSMaxRange(tracked), NSMaxRange(edit)) + delta
        return NSRange(location: start, length: max(0, end - start))
    }

    // MARK: - Screenshot

    /// The screenshot hotkey: dims the screen for a drag-selection (the panel
    /// steps aside if it's open). The selected piece opens the widget with the
    /// image attached, its text recognized and translated. Esc, a plain click
    /// or the hotkey again cancels. Selected text isn't picked up here.
    func startScreenshot() {
        DebugLog.log("screenshot: hotkey (capturing=\(capturing) busy=\(isInputBusy) screenAccess=\(CGPreflightScreenCaptureAccess()))")
        guard !capturing else { cancelScreenshot(); return }
        guard !isInputBusy, !dictation.isRunning else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess() // macOS's own prompt (shown once)
            if desiredState != .shown { show() }
            showInputError(message: "Needs Screen Recording access",
                           settingsPane: "Privacy_ScreenCapture")
            return
        }
        capturing = true
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        if desiredState == .shown { panel.orderOut(nil) } // its content waits for the shot
        if let screen { dimWindow.setFrame(screen.frame, display: false) }
        dimWindow.selectionView.selectionEnabled = true
        DebugLog.log("screenshot: backdrop over \(Int(dimWindow.frame.width))×\(Int(dimWindow.frame.height)) at \(Int(dimWindow.frame.minX)),\(Int(dimWindow.frame.minY))")
        dimWindow.acceptsKey = true
        dimWindow.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        dimWindow.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            dimWindow.animator().alphaValue = 1
        }
    }

    private func endScreenshotMode() {
        capturing = false
        dimWindow.selectionView.selectionEnabled = false
        dimWindow.acceptsKey = false
    }

    /// Back to where we were: the open widget, or nothing (focus returns).
    private func cancelScreenshot() {
        guard capturing else { return }
        DebugLog.log("screenshot: cancelled")
        endScreenshotMode()
        if desiredState == .shown {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(inputView)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            dimWindow.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, !self.capturing, self.desiredState == .hidden else { return }
            self.dimWindow.orderOut(nil)
            NSApp.deactivate()
        })
    }

    /// The dimmed backdrop was clicked (no drag).
    private func backdropClicked() {
        if capturing {
            cancelScreenshot()
        } else {
            handleOutsideClick(at: NSEvent.mouseLocation)
        }
    }

    /// A piece of the screen selected on the dimmed backdrop (global
    /// coordinates): step our windows aside, shoot it with the system
    /// `screencapture`, bring the widget up and attach the image.
    private func captureScreen(_ rect: NSRect) {
        DebugLog.log("screenshot: selected \(Int(rect.width))×\(Int(rect.height)) at \(Int(rect.minX)),\(Int(rect.minY))")
        guard CGPreflightScreenCaptureAccess() else { // revoked while selecting
            endScreenshotMode()
            if desiredState != .shown { show() }
            showInputError(message: "Needs Screen Recording access",
                           settingsPane: "Privacy_ScreenCapture")
            return
        }
        // screencapture wants top-left-origin coordinates of the main display.
        let mainHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let region = String(format: "%.0f,%.0f,%.0f,%.0f", rect.minX, mainHeight - rect.maxY, rect.width, rect.height)
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranslateWidget-\(UUID().uuidString).png")

        panel.orderOut(nil) // out of the shot
        dimWindow.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in // let the windows actually go
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R" + region, file.path]
            process.terminationHandler = { finished in
                DispatchQueue.main.async {
                    let image = NSImage(contentsOf: file)
                    DebugLog.log("screenshot: screencapture -R\(region) exit=\(finished.terminationStatus) image=\(image.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none")")
                    try? FileManager.default.removeItem(at: file)
                    self?.returnFromCapture(with: image)
                }
            }
            do {
                try process.run()
            } catch {
                DebugLog.log("screenshot: couldn't run screencapture: \(error)")
                self?.returnFromCapture(with: nil)
            }
        }
    }

    private func returnFromCapture(with image: NSImage?) {
        endScreenshotMode()
        if desiredState == .shown { // the widget was open — bring it back as it was
            dimWindow.alphaValue = 0
            dimWindow.orderFront(nil)
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(inputView)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                dimWindow.animator().alphaValue = 1
            }
        } else {
            show() // opens fresh
        }
        guard let image else {
            showInputError(message: "Couldn't take the screenshot")
            return
        }
        attachImage(image)
    }

    /// Replaces `range` of the input as one undoable edit (keeps the caption).
    private func replaceInput(_ range: NSRange, with text: String) {
        guard inputView.shouldChangeText(in: range, replacementString: text) else { return }
        applyingEdit = true
        inputView.replaceCharacters(in: range, with: text)
        inputView.didChangeText()
        applyingEdit = false
        inputView.setSelectedRange(NSRange(location: range.location + (text as NSString).length, length: 0))
        panel.makeFirstResponder(inputView)
    }

    /// Dashed "drop an image" highlight. Moving between the input and the rest
    /// of the panel fires exit/enter back to back — hiding waits a beat so the
    /// highlight doesn't flicker.
    private func setDropHighlight(_ on: Bool) {
        dropHoverOff?.cancel()
        guard on else {
            let work = DispatchWorkItem { [weak self] in self?.fadeDropOverlay(visible: false) }
            dropHoverOff = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
            return
        }
        fadeDropOverlay(visible: true)
    }

    private func fadeDropOverlay(visible: Bool) {
        if visible, dropOverlay.isHidden {
            dropOverlay.alphaValue = 0
            dropOverlay.isHidden = false
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            self.dropOverlay.animator().alphaValue = visible ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !visible, self.dropOverlay.alphaValue == 0 else { return }
            self.dropOverlay.isHidden = true
        })
    }

    /// While a fix or a recognition runs, the input can't be edited and its
    /// lines shimmer as a skeleton.
    private func setInputBusy(_ busy: Bool) {
        isInputBusy = busy
        inputView.isEditable = !busy
        magicButton.alphaValue = busy ? 0.5 : 1
        if busy {
            var lines = lineRects(of: inputView, in: inputSkeleton)
            if lines.isEmpty { lines = [CGRect(x: 2, y: 4, width: 120, height: 22)] }
            inputSkeleton.setLines(lines)
            if inputSkeleton.isHidden {
                inputSkeleton.alphaValue = 0
                inputSkeleton.isHidden = false
            }
            inputSkeleton.startShimmer()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = busy ? 0.16 : 0.2
            self.inputSkeleton.animator().alphaValue = busy ? 1 : 0
            self.inputScroll.animator().alphaValue = busy ? 0 : 1
        }, completionHandler: { [weak self] in
            guard let self, !self.isInputBusy else { return }
            self.inputSkeleton.isHidden = true
            self.inputSkeleton.stopShimmer()
        })
    }

    private var hasInputCaption: Bool { !inputCaption.stringValue.isEmpty }

    private func showInputCaption(_ text: String) {
        inputCaption.stringValue = text
        inputCaption.textColor = .secondaryLabelColor
        inputCopyButton.isHidden = false
        inputErrorCopyButton.isHidden = true
        setSettingsPane(nil)
        inputCaptionRow.isHidden = false
        relayout(animated: true)
    }

    private func showInputError(_ error: Error) {
        let (display, details) = Self.describe(error)
        showInputError(message: display, details: details)
    }

    /// `settingsPane` (a Privacy & Security anchor such as "Privacy_Accessibility")
    /// adds an "Open Settings" button instead of the copy-error one.
    private func showInputError(message display: String, details: String? = nil, settingsPane: String? = nil) {
        lastErrorMessage = details ?? display
        inputCaption.stringValue = "⚠︎ \(display)"
        inputCaption.textColor = .systemRed
        inputCopyButton.isHidden = true
        setSettingsPane(settingsPane)
        inputErrorCopyButton.isHidden = settingsPane != nil
        inputCaptionRow.isHidden = false
        relayout(animated: true)
    }

    private func clearInputCaption() {
        guard hasInputCaption else { return }
        inputCaption.stringValue = ""
        inputCopyButton.isHidden = true
        inputErrorCopyButton.isHidden = true
        setSettingsPane(nil)
        inputCaptionRow.isHidden = true
    }

    private func setSettingsPane(_ anchor: String?) {
        settingsPaneURL = anchor.flatMap { URL(string: "x-apple.systempreferences:com.apple.preference.security?\($0)") }
        inputSettingsButton.isHidden = settingsPaneURL == nil
    }

    @objc private func openSettingsPane() {
        guard let settingsPaneURL else { return }
        NSWorkspace.shared.open(settingsPaneURL)
    }

    /// Only records the manner — fixing itself happens on the button.
    private func setLevel(_ level: Int) {
        fixLevel = min(max(level, 1), 3)
        UserDefaults.standard.set(fixLevel, forKey: "fixLevel")
        mannerButton.selectedValue = String(fixLevel)
    }

    // MARK: - Loading skeleton

    /// While a result loads, its text turns into shimmering bars. When there's
    /// already text, wait a beat first so fast answers don't flash.
    private func setLoading(_ loading: Bool) {
        isLoading = loading
        skeletonDelay?.cancel()
        if loading {
            guard !skeletonShown else { return }
            if outputView.string.isEmpty {
                showSkeleton()
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.isLoading else { return }
                    self.showSkeleton()
                }
                skeletonDelay = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        } else if skeletonShown {
            hideSkeleton()
        }
    }

    private func showSkeleton() {
        skeletonShown = true
        let lines = skeletonLineRects()
        skeleton.setLines(lines)
        skeletonHeight = (lines.map(\.maxY).max() ?? 0) + 4
        if skeleton.isHidden {
            skeleton.alphaValue = 0
            skeleton.isHidden = false
        }
        skeleton.startShimmer()
        relayout(animated: true)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            self.skeleton.animator().alphaValue = 1
            self.outputScroll.animator().alphaValue = 0
            self.copyButton.animator().alphaValue = 0
        }
    }

    private func hideSkeleton() {
        skeletonShown = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            self.skeleton.animator().alphaValue = 0
            self.outputScroll.animator().alphaValue = 1
            self.copyButton.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            guard let self, !self.skeletonShown else { return }
            self.skeleton.isHidden = true
            self.skeleton.stopShimmer()
        })
    }

    /// One rect per line of the current result, in skeleton coordinates. With no
    /// result yet, estimate from the input: same font, so roughly the same length.
    private func skeletonLineRects() -> [CGRect] {
        var rects = lineRects(of: outputView, in: skeleton)
        guard rects.isEmpty else { return rects }

        let lineHeight: CGFloat = 22
        let available = max(skeleton.bounds.width - 4, 80)
        var remaining = max(lineRects(of: inputView, in: inputView).reduce(0) { $0 + $1.width }, 60)
        var y: CGFloat = 4
        while remaining > 0, rects.count < 4 {
            rects.append(CGRect(x: 2, y: y, width: min(remaining, available), height: lineHeight))
            remaining -= available
            y += lineHeight
        }
        return rects
    }

    /// One rect per laid-out line of `textView`, in `view`'s coordinates.
    private func lineRects(of textView: NSTextView, in view: NSView) -> [CGRect] {
        guard !textView.string.isEmpty,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let origin = textView.textContainerOrigin
        var rects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, used, _, _, _ in
            rects.append(textView.convert(used.offsetBy(dx: origin.x, dy: origin.y), to: view))
        }
        return rects
    }

    // MARK: - Status line

    /// Splits an error into a short display line and full copyable details.
    static func describe(_ error: Error) -> (display: String, details: String) {
        if let te = error as? TranslationError {
            return (te.errorDescription ?? "\(te)", te.debugDetails)
        }
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return (message, message)
    }

    /// Show an error with a copy button next to it. The copy button yields the
    /// full server response (for debugging), not just the short line.
    private func showError(_ error: Error) {
        let (display, details) = Self.describe(error)
        lastErrorMessage = details
        statusLabel.stringValue = "⚠︎ \(display)"
        statusLabel.textColor = .systemRed
        statusLabel.isHidden = false
        errorCopyButton.isHidden = false
        relayout(animated: true)
    }

    /// Show a neutral status note (no copy button).
    private func showInfo(_ message: String) {
        statusLabel.stringValue = message
        statusLabel.textColor = .secondaryLabelColor
        errorCopyButton.isHidden = true
    }

    private func clearStatus() {
        statusLabel.stringValue = ""
        statusLabel.textColor = .secondaryLabelColor
        errorCopyButton.isHidden = true
    }

    @objc private func copyError() {
        guard !lastErrorMessage.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lastErrorMessage, forType: .string)
    }

    private func announce(_ string: String) {
        guard !string.isEmpty else { return }
        NSAccessibility.post(element: outputView as Any,
                             notification: .announcementRequested,
                             userInfo: [.announcement: string,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    @objc private func copyOutput() { copy(outputView.string, feedbackOn: copyButton) }
    @objc private func copyInput() { copy(inputView.string, feedbackOn: inputCopyButton) }

    /// Copies and flips the button to a checkmark for a moment.
    private func copy(_ text: String, feedbackOn button: HoverButton) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        setCopyAppearance(button, copied: true)
        bounce(button)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.setCopyAppearance(button, copied: false)
        }
    }

    private func makeCopyButton(pointSize: CGFloat, action: Selector) -> HoverButton {
        let button = HoverButton()
        button.imagePosition = .imageOnly
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        button.hoverColor = NSColor(white: 0.94, alpha: 1)
        button.target = self
        button.action = action
        button.toolTip = "Copy"
        setCopyAppearance(button, copied: false)
        return button
    }

    private func setCopyAppearance(_ button: HoverButton, copied: Bool) {
        button.image = NSImage(systemSymbolName: copied ? "checkmark" : "square.on.square",
                               accessibilityDescription: copied ? "Copied" : "Copy")
        button.contentTintColor = copied ? NSColor(white: 0.1, alpha: 1) : NSColor(white: 0.45, alpha: 1)
    }

    // MARK: - Dictation

    @objc private func toggleDictation() {
        DebugLog.log("toggleDictation tapped (isRunning=\(dictation.isRunning))")
        if dictation.isRunning {
            dictation.stop() // keeps the recognized text
            return
        }
        guard !isInputBusy else { return } // the input is locked while it's being rewritten
        awaitingAuth = true
        DictationManager.requestAuthorization { [weak self] granted in
            guard let self else { return }
            self.awaitingAuth = false
            DebugLog.log("auth callback granted=\(granted) desiredState=\(self.desiredState == .shown ? "shown" : "hidden")")
            guard granted else {
                self.showError(DictationManager.DictationError.denied)
                return
            }
            guard self.desiredState == .shown else { return } // panel closed while we asked
            self.startDictation()
        }
    }

    private func startDictation() {
        // Spoken words are appended after whatever is already in the field
        // (rewritten wholesale on each update, so images let go of their text).
        detachAllImages()
        dictationBaseText = inputView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        dictationCancelled = false

        dictation.onText = { [weak self] spoken in
            guard let self, !self.dictationCancelled else { return }
            let base = self.dictationBaseText
            let full = base.isEmpty ? spoken : base + " " + spoken
            self.inputView.string = full
            self.inputView.needsDisplay = true
            // The recognized text takes over from the red waveform as it streams in.
            self.revealRecognizedText(!full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            self.scheduleTranslate()
            self.relayout(animated: true)
        }
        dictation.onLevel = { [weak self] level in
            self?.waveform.level = CGFloat(level)
        }
        dictation.onError = { [weak self] error in
            guard let self else { return }
            self.setDictationActive(false)
            self.showError(error)
        }
        dictation.onStop = { [weak self] in self?.setDictationActive(false) }

        setDictationActive(true)
        dictation.start(localeCode: sourceSelection)
    }

    private func setMicAppearance(active: Bool) {
        micButton.image = NSImage(systemSymbolName: active ? "stop.circle.fill" : "mic",
                                  accessibilityDescription: active ? "Stop dictation" : "Start dictation")
        micButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: active ? 18 : 16, weight: .regular)
        micButton.contentTintColor = active ? .systemRed : NSColor(white: 0.40, alpha: 1)
        micButton.toolTip = active ? "Stop dictation" : "Dictate (voice input)"
        micButton.setAccessibilityLabel(active ? "Stop dictation" : "Start dictation")
    }

    /// Switches the panel between normal and "listening" chrome. While listening
    /// the red waveform shows until words are recognized; the live text then
    /// takes over the input row (see `revealRecognizedText`).
    private func setDictationActive(_ active: Bool) {
        setMicAppearance(active: active)
        pulseMic(active)

        if active {
            statusLabel.isHidden = true
            errorCopyButton.isHidden = true
            waveform.isHidden = false
            waveform.start()
            // Show the waveform if there's nothing yet; otherwise keep the text up.
            inputScroll.alphaValue = hasInput ? 1 : 0
            waveform.alphaValue = hasInput ? 0 : 1
        } else {
            waveform.stop()
            statusLabel.isHidden = false
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                self.inputScroll.animator().alphaValue = 1
                self.waveform.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.waveform.isHidden = true
            })
            relayout(animated: true)
        }
    }

    /// During dictation, cross-fade between the red waveform (no words yet) and
    /// the live recognized text as it streams in.
    private func revealRecognizedText(_ hasText: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.inputScroll.animator().alphaValue = hasText ? 1 : 0
            self.waveform.animator().alphaValue = hasText ? 0 : 1
        }
    }

    /// Gentle breathing on the mic button while it's listening.
    private func pulseMic(_ on: Bool) {
        let key = "dictationPulse"
        guard on else { micButton.layer?.removeAnimation(forKey: key); return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.4
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        micButton.layer?.add(pulse, forKey: key)
    }

    /// A small springy "tap" on a control after it changes something.
    private func bounce(_ view: NSView) {
        guard let layer = view.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: view.centeredTransform(scale: 0.78))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 500
        spring.damping = 18
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "bounce")
    }

    // MARK: - Auto-resize

    private var hasStatusLine: Bool {
        !statusLabel.isHidden && !statusLabel.stringValue.isEmpty
    }

    /// The result area opens as soon as there's text (translation is live) or a
    /// status/error to show.
    private var isExpanded: Bool { hasInput || hasStatusLine }

    private func relayout(animated: Bool) {
        body.layoutSubtreeIfNeeded()

        let inputHeight = clamp(contentHeight(inputView), inputMinHeight, inputMaxHeight)
        let expanded = isExpanded
        let footer = hasStatusLine ? footerGap + footerHeight : 0
        let resultHeight = max(contentHeight(outputView), skeletonShown ? skeletonHeight : 0)
        let outputHeight = expanded
            ? 1 + outputGap + clamp(resultHeight, outputMinHeight, outputMaxHeight) + footer
            : 0

        let caption = hasInputCaption ? inputCaptionHeight : 0 // sits between the input and the result

        inputHeightC.constant = inputHeight
        outputTopGapC.constant = caption + (expanded ? sectionGap : 0)
        outputHeightC.constant = outputHeight
        outputBottomC.constant = -footer

        let cardHeight = vPad + inputHeight + caption
            + (expanded ? sectionGap + outputHeight + expandedBottomPad : vPad)

        var frame = panel.frame
        frame.size = NSSize(width: cardWidth + margin * 2, height: cardHeight + margin * 2)
        // Keep the bottom edge fixed (origin.y unchanged) so the panel grows upward.

        copyButton.isHidden = !expanded || outputView.string.isEmpty

        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
                context.allowsImplicitAnimation = true
                self.outputContainer.animator().alphaValue = expanded ? 1 : 0
                self.panel.animator().setFrame(frame, display: true)
                self.body.layoutSubtreeIfNeeded()
            }
        } else {
            outputContainer.alphaValue = expanded ? 1 : 0
            panel.setFrame(frame, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func contentHeight(_ textView: NSTextView) -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return inputMinHeight
        }
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height) + textView.textContainerInset.height * 2
    }

    private func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(max(value, low), high)
    }

    // MARK: - Keyboard language

    /// The language of the **current keyboard input source** (falls back to the
    /// active keyboard layout, then the macOS display language). Read once per
    /// open to pick the default target.
    private static func currentInputLanguageCode() -> String {
        func language(of source: TISInputSource?) -> String? {
            guard let source,
                  let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else { return nil }
            let languages = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
            guard let first = languages?.first else { return nil }
            return Locale(identifier: first).language.languageCode?.identifier
        }
        // The active source can be a non-keyboard method (emoji, Press-and-Hold);
        // fall back to the active keyboard layout, then to the display language.
        if let code = language(of: TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()) { return code }
        if let code = language(of: TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()) { return code }
        return appleDisplayLanguageCode()
    }

    private static func appleDisplayLanguageCode() -> String {
        // Query cfprefsd directly for AppleLanguages so a display-language change is
        // picked up without relaunching (Locale.preferredLanguages is cached per process).
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let raw = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                         kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        if let languages = raw as? [String], let first = languages.first,
           let code = Locale(identifier: first).language.languageCode?.identifier {
            return code
        }
        if let preferred = Locale.preferredLanguages.first,
           let code = Locale(identifier: preferred).language.languageCode?.identifier {
            return code
        }
        return Locale.autoupdatingCurrent.language.languageCode?.identifier ?? "en"
    }

    // MARK: - Show / hide

    /// `sourceFromKeyboard: false` keeps the source as set (Detect for picked-up text).
    private func show(sourceFromKeyboard: Bool = true) {
        if capturing { endScreenshotMode() } // opened some other way mid-selection
        resetIfPending()
        desiredState = .shown
        let previousPair = (sourceSelection, targetSelection)
        if sourceFromKeyboard { adoptKeyboardLanguageAsSource() }
        relayout(animated: false)

        let screen = NSScreen.main ?? NSScreen.screens.first
        panel.setFrame(panelFrame(height: panel.frame.height, on: screen), display: false)

        // Dim the screen behind the panel.
        if let screen { dimWindow.setFrame(screen.frame, display: false) }
        dimWindow.alphaValue = 0
        dimWindow.orderFront(nil)

        card.layer?.removeAllAnimations()
        card.alphaValue = 1
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(inputView)
        for button in [micButton, sourceButton, swapButton, targetButton, mannerButton, copyButton, inputCopyButton] {
            button?.syncHoverWithMouse()
        }

        animateIn()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            dimWindow.animator().alphaValue = 1
        }

        if previousPair != (sourceSelection, targetSelection), hasInput { translateNow() }
    }

    private func hide() {
        guard desiredState == .shown else { return }
        if capturing { endScreenshotMode() }
        desiredState = .hidden
        pendingReset = true // every open starts blank
        if dictation.isRunning { dictation.stop() }

        animateOut { [weak self] in
            guard let self, self.desiredState == .hidden else { return } // a newer show() won
            self.panel.orderOut(nil)
            self.dimWindow.orderOut(nil)
            self.card.layer?.removeAllAnimations()
            self.card.alphaValue = 1
            self.resetIfPending() // out of sight, so the content doesn't visibly empty
            // Hand focus back to the app the widget was called from (unless one of
            // our own windows, like Settings, is open).
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.deactivate()
            }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            dimWindow.animator().alphaValue = 0
        }
    }

    private func resetIfPending() {
        guard pendingReset else { return }
        pendingReset = false
        resetContent()
    }

    /// Back to a blank widget: no text, translation, images, captions or
    /// in-flight requests. Language and manner settings stay; the target goes
    /// back to the saved one (a detected-language flip was only for that text).
    private func resetContent() {
        pendingTranslate?.cancel()
        requestToken += 1 // late results are dropped
        inputToken += 1

        skeletonDelay?.cancel()
        isLoading = false
        skeletonShown = false
        skeleton.stopShimmer()
        skeleton.isHidden = true
        skeleton.alphaValue = 0
        isInputBusy = false
        inputView.isEditable = true
        magicButton.alphaValue = 1
        inputSkeleton.stopShimmer()
        inputSkeleton.isHidden = true
        inputSkeleton.alphaValue = 0
        inputScroll.alphaValue = 1
        outputScroll.alphaValue = 1
        copyButton.alphaValue = 1
        setCopyAppearance(copyButton, copied: false)
        setCopyAppearance(inputCopyButton, copied: false)

        detachAllImages()
        previewPopover?.close()
        dropHoverOff?.cancel()
        dropOverlay.isHidden = true
        dropOverlay.alphaValue = 0

        inputView.string = ""
        inputView.undoManager?.removeAllActions()
        outputView.string = ""
        clearInputCaption()
        clearStatus()
        lastDetected = nil
        targetSelection = UserDefaults.standard.string(forKey: "targetLang") ?? targetSelection
        refreshLanguageMenus()
        relayout(animated: false)
    }

    /// iOS-style entrance: rises and scales up with a spring that slightly
    /// overshoots and settles (the little bounce at the end).
    private func animateIn() {
        guard let layer = card.layer else { return }
        card.layoutSubtreeIfNeeded()

        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: card.centeredTransform(scale: 0.88, dy: -18))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.mass = 1
        spring.stiffness = 380
        spring.damping = 21 // ζ ≈ 0.54 → ~13% overshoot, settles in ~0.45s
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)

        layer.add(spring, forKey: "appear")
        layer.add(fade, forKey: "appearFade")
    }

    /// Quick exit: shrinks slightly and fades.
    private func animateOut(completion: @escaping () -> Void) {
        guard let layer = card.layer else { completion(); return }
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)

        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: card.centeredTransform(scale: 0.94, dy: -8))
        shrink.duration = 0.14
        shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.14
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)

        layer.removeAllAnimations()
        card.alphaValue = 0
        layer.add(shrink, forKey: "disappear")
        layer.add(fade, forKey: "disappearFade")
        CATransaction.commit()
    }

    /// Window frame (card + shadow margin) with the card centered near the bottom.
    private func panelFrame(height: CGFloat, on screen: NSScreen?) -> NSRect {
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let width = cardWidth + margin * 2
        return NSRect(x: visible.midX - width / 2, y: visible.minY + 120 - margin, width: width, height: height)
    }

    /// The card's rect in screen coordinates (the window also has a shadow margin).
    private var cardScreenRect: NSRect {
        panel.convertToScreen(card.convert(card.bounds, to: nil))
    }

    /// Esc closes the panel.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.desiredState == .shown || self.capturing else { return event }
            guard event.window === self.panel || event.window === self.dimWindow || event.window == nil else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                if self.capturing { self.cancelScreenshot() } else { self.hide() }
                return nil
            }
            return event
        }
    }

    /// Dismiss the panel when the user clicks anywhere outside the card. On this
    /// screen the dimmed backdrop reports plain clicks itself (drags there take a
    /// screenshot); the local monitor covers the panel's margin and our other
    /// windows (menu-bar item), the global one other screens / other apps.
    /// NSMenu tracking runs its own loop, so picking from a menu doesn't route
    /// through these monitors.
    private func installOutsideClickMonitors() {
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.handleOutsideClick(at: NSEvent.mouseLocation, source: "global")
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            // The dimmed backdrop decides itself (a click closes, a drag screenshots),
            // and the image preview popover is part of the widget.
            if event.window === self.dimWindow { return event }
            if let popoverWindow = self.previewPopover?.contentViewController?.view.window,
               event.window === popoverWindow { return event }
            self.handleOutsideClick(at: NSEvent.mouseLocation, source: "local")
            return event
        }
    }

    private func handleOutsideClick(at screenPoint: NSPoint, source: String = "backdrop") {
        if capturing {
            // The very click that starts a selection can also reach the monitors
            // (while macOS is still handing us activation) — anything on the dimmed
            // screen belongs to the selection. Only a click on another screen cancels.
            guard !dimWindow.frame.contains(screenPoint) else { return }
            DebugLog.log("screenshot: click on another screen (\(source)) — cancelling")
            cancelScreenshot()
            return
        }
        guard desiredState == .shown else { return }
        // Don't dismiss while the one-time mic/speech permission dialog is up.
        guard !awaitingAuth else { return }
        guard !cardScreenRect.contains(screenPoint) else { return }
        suppressReopen = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.suppressReopen = false }
        hide()
    }

    @objc private func openPreferences() {
        onOpenPreferences?()
    }
}
