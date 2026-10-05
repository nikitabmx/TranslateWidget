import Cocoa

// Building blocks for the Claude-style quick-entry bar: a white rounded card
// with a soft shadow, borderless hover buttons, "Title ⌄" menu buttons, the
// small black glyph button, the skeleton loader, and the translucent screen
// dimmer behind the panel.

extension NSView {
    /// A transform that scales (and optionally shifts) the view's layer about its
    /// visual center, regardless of the layer's anchor point (AppKit uses 0,0).
    func centeredTransform(scale: CGFloat, dy: CGFloat = 0) -> CATransform3D {
        let anchor = layer?.anchorPoint ?? .zero
        let cx = bounds.width * (0.5 - anchor.x)
        let cy = bounds.height * (0.5 - anchor.y)
        var t = CATransform3DMakeTranslation(cx, cy + dy, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        t = CATransform3DTranslate(t, -cx, -cy, 0)
        return t
    }

    /// A bitmap of the view as it currently looks (for fly-around animations).
    func snapshotImage() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}

// MARK: - Card

/// Invisible view whose only job is to cast a rounded shadow.
private final class ShadowView: NSView {
    var cornerRadius: CGFloat = 22

    init(opacity: Float, radius: CGFloat, offsetY: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = opacity
        layer?.shadowRadius = radius
        layer?.shadowOffset = CGSize(width: 0, height: offsetY)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius,
                                   cornerHeight: cornerRadius, transform: nil)
    }
}

/// White rounded card with a hairline border and a two-layer (ambient + contact)
/// shadow. Put content into `content`.
final class ShadowCardView: NSView {
    let content = NSView()

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = false
        translatesAutoresizingMaskIntoConstraints = false

        let ambient = ShadowView(opacity: 0.13, radius: 26, offsetY: -12)
        let contact = ShadowView(opacity: 0.07, radius: 2, offsetY: -1)
        for shadow in [ambient, contact] {
            shadow.cornerRadius = cornerRadius
            addSubview(shadow)
            pin(shadow)
        }

        content.wantsLayer = true
        content.translatesAutoresizingMaskIntoConstraints = false
        content.layer?.backgroundColor = NSColor.white.cgColor
        content.layer?.cornerRadius = cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        addSubview(content)
        pin(content)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func pin(_ view: NSView) {
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.topAnchor.constraint(equalTo: topAnchor),
            view.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
}

// MARK: - Buttons

/// Borderless button with a soft rounded highlight on hover (and an optional
/// resting background).
class HoverButton: NSButton {
    var hoverColor = NSColor.black.withAlphaComponent(0.055)
    var restingColor: NSColor? { didSet { refreshBackground() } }
    private var trackingArea: NSTrackingArea?

    var isHovering = false { didSet { refreshBackground() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // NSButton pads its frame around the "alignment rect" for bezel styles; with
    // no bezel we want the frame to be exactly the size we constrain it to.
    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override var isEnabled: Bool { didSet { refreshBackground() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }

    // A button is never a text spot: always the arrow.
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Re-sync hover after something (a menu, a hide) swallowed mouseExited.
    func syncHoverWithMouse() {
        guard let window else { isHovering = false; return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        isHovering = window.isVisible && bounds.contains(point)
    }

    func refreshBackground() {
        layer?.backgroundColor = (isHovering && isEnabled) ? hoverColor.cgColor : restingColor?.cgColor
    }
}

/// "Title ⌄" button that pops a checkmarked menu — like "New Chat ⌄" in the
/// Claude quick-entry bar.
final class MenuButton: HoverButton {
    struct Item {
        let title: String
        let value: String
        var detail: String? = nil // gray hint shown after the title in the menu only
    }

    var items: [Item] = [] { didSet { refresh() } }
    var selectedValue = "" { didSet { refresh() } }
    var onSelect: ((String) -> Void)?

    private static let titleFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    private static let titleColor = NSColor(white: 0.40, alpha: 1)
    private static let chevron = NSImage.symbol(["chevron.down"], pointSize: 9, weight: .bold, color: titleColor)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imagePosition = .noImage
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The chevron rides inside the title as a text attachment, centered on the
    /// cap height — NSButton's own image placement lets it sag below the text.
    private func refresh() {
        let text = items.first { $0.value == selectedValue }?.title ?? ""
        let title = NSMutableAttributedString(string: text + " ", attributes: [
            .font: Self.titleFont, .foregroundColor: Self.titleColor,
        ])
        if let chevron = Self.chevron {
            let attachment = NSTextAttachment()
            attachment.image = chevron
            let y = ((Self.titleFont.capHeight - chevron.size.height) / 2 * 2).rounded() / 2 // snap to half points
            attachment.bounds = CGRect(x: 0, y: y, width: chevron.size.width, height: chevron.size.height)
            title.append(NSAttributedString(attachment: attachment))
        }
        attributedTitle = title
        setAccessibilityValue(text)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: base.width + 18, height: 30)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !items.isEmpty else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            let menuItem = NSMenuItem(title: item.title, action: #selector(pick(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item.value
            menuItem.state = item.value == selectedValue ? .on : .off
            if let detail = item.detail {
                let title = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                title.append(NSAttributedString(string: "  " + detail, attributes: [
                    .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                menuItem.attributedTitle = title
            }
            menu.addItem(menuItem)
        }
        isHovering = true
        let below = NSPoint(x: 0, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
        menu.popUp(positioning: nil, at: below, in: self)
        syncHoverWithMouse()
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        onSelect?(value)
    }
}

extension NSImage {
    /// The first available SF Symbol from `names`, filled with a solid color as a
    /// regular (non-template) image, so no tinting, vibrancy or disabled dimming
    /// can change it.
    static func symbol(_ names: [String], pointSize: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let symbol = names.lazy
            .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) })
            .first else { return nil }
        let image = NSImage(size: symbol.size, flipped: false) { rect in
            symbol.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Small square black button with a white glyph — Claude's orange ↑, here the
/// fix sparkles. A plain NSView rather than NSButton, so AppKit never pads its
/// frame, re-tints or dims the glyph. Presses squish it; release springs back.
final class GlyphButton: NSView {
    var onPress: (() -> Void)?

    private let side: CGFloat
    private let glyph = NSImageView()
    private let normal = NSColor(white: 0.07, alpha: 1)
    private let hover = NSColor(white: 0.20, alpha: 1)
    private var trackingArea: NSTrackingArea?
    private var isHovering = false { didSet { refreshBackground() } }
    private var isPressed = false

    init(symbols: [String], side: CGFloat = 28, pointSize: CGFloat = 13) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = normal.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        glyph.image = NSImage.symbol(symbols, pointSize: pointSize, weight: .semibold, color: .white)
        glyph.imageScaling = .scaleNone
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // The whole square is the hit target (not the glyph image view).
    override func hitTest(_ point: NSPoint) -> NSView? {
        !isHidden && frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseDown(with event: NSEvent) { setPressed(true) }

    override func mouseDragged(with event: NSEvent) {
        setPressed(bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setPressed(false)
        if inside { onPress?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }

    private func refreshBackground() {
        layer?.backgroundColor = (isHovering ? hover : normal).cgColor
    }

    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed, let layer else { return }
        isPressed = pressed
        let current = layer.presentation()?.transform ?? CATransform3DIdentity
        if pressed {
            let squish = CABasicAnimation(keyPath: "transform")
            squish.fromValue = NSValue(caTransform3D: current)
            squish.toValue = NSValue(caTransform3D: centeredTransform(scale: 0.88))
            squish.duration = 0.09
            squish.timingFunction = CAMediaTimingFunction(name: .easeOut)
            squish.fillMode = .forwards
            squish.isRemovedOnCompletion = false
            layer.add(squish, forKey: "press")
        } else {
            let release = CASpringAnimation(keyPath: "transform")
            release.fromValue = NSValue(caTransform3D: current)
            release.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            release.mass = 1
            release.stiffness = 520
            release.damping = 15 // bouncy settle
            release.duration = release.settlingDuration
            layer.add(release, forKey: "press")
        }
    }
}

// MARK: - Skeleton loader

/// Shimmering rounded bars laid over text lines while a result loads — the
/// text "turns into" gray lines of the same length.
final class SkeletonView: NSView {
    private let shimmer = CAGradientLayer()
    private let barsMask = CAShapeLayer()
    private var lineRects: [CGRect] = []
    private let barHeight: CGFloat = 12

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        let base = NSColor(white: 0.91, alpha: 1).cgColor
        let light = NSColor(white: 0.975, alpha: 1).cgColor
        shimmer.colors = [base, light, base]
        shimmer.locations = [-1, -0.5, 0]
        shimmer.startPoint = CGPoint(x: 0, y: 0.5)
        shimmer.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.mask = barsMask
        layer?.addSublayer(shimmer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// One bar per text line; rects are in this view's (flipped) coordinates.
    func setLines(_ rects: [CGRect]) {
        lineRects = rects
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shimmer.frame = convertToLayer(bounds)
        barsMask.frame = shimmer.bounds
        let path = CGMutablePath()
        for line in lineRects where line.intersects(bounds) {
            let bar = NSRect(x: line.minX, y: line.midY - barHeight / 2,
                             width: min(max(line.width, 28), bounds.width - line.minX), height: barHeight)
            // View coords → layer coords (handles flipping), then into the mask's space.
            let rect = convertToLayer(bar).offsetBy(dx: -shimmer.frame.minX, dy: -shimmer.frame.minY)
            path.addRoundedRect(in: rect, cornerWidth: barHeight / 2, cornerHeight: barHeight / 2)
        }
        barsMask.path = path
        CATransaction.commit()
    }

    func startShimmer() {
        guard shimmer.animation(forKey: "shimmer") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "locations")
        sweep.fromValue = [-1.0, -0.5, 0.0]
        sweep.toValue = [1.0, 1.5, 2.0]
        sweep.duration = 1.2
        sweep.repeatCount = .infinity
        shimmer.add(sweep, forKey: "shimmer")
    }

    func stopShimmer() {
        shimmer.removeAnimation(forKey: "shimmer")
    }
}

// MARK: - Image drop highlight

/// Shown over the card while an image is dragged onto it: a dashed outline and
/// a hint. Invisible to clicks and drags, so the drop still lands underneath.
final class DropOverlayView: NSView {
    private let outline = CAShapeLayer()
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.94).cgColor
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous

        outline.fillColor = nil
        outline.strokeColor = NSColor.black.withAlphaComponent(0.22).cgColor
        outline.lineWidth = 1.5
        outline.lineDashPattern = [6, 4]
        layer?.addSublayer(outline)

        let icon = NSImageView(image: NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = NSColor(white: 0.35, alpha: 1)
        let label = NSTextField(labelWithString: "Drop an image to recognize its text")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = NSColor(white: 0.35, alpha: 1)
        let hint = NSStackView(views: [icon, label])
        hint.orientation = .horizontal
        hint.spacing = 8
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let frame = convertToLayer(bounds)
        outline.frame = frame
        let inset = frame.insetBy(dx: 5, dy: 5)
        outline.path = CGPath(roundedRect: CGRect(origin: CGPoint(x: 5, y: 5), size: inset.size),
                              cornerWidth: cornerRadius - 5, cornerHeight: cornerRadius - 5, transform: nil)
        CATransaction.commit()
    }
}

// MARK: - Image chip

/// An attached image in the input row — thumbnail + "Image", like attachments
/// in Claude's quick entry. Click opens a preview; the ✕ (on hover) removes it.
final class ImageChipView: NSView {
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?

    private let removeButton = HoverButton()
    private var trackingArea: NSTrackingArea?

    init(image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        layer?.backgroundColor = NSColor(white: 0.955, alpha: 1).cgColor
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.08).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Attached image")

        let thumbnail = NSView()
        thumbnail.wantsLayer = true
        thumbnail.layer?.contents = image
        thumbnail.layer?.contentsGravity = .resizeAspectFill
        thumbnail.layer?.cornerRadius = 5
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.layer?.borderWidth = 0.5
        thumbnail.layer?.borderColor = NSColor.black.withAlphaComponent(0.1).cgColor
        thumbnail.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Image")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(white: 0.2, alpha: 1)
        label.translatesAutoresizingMaskIntoConstraints = false

        removeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Remove image")
        removeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        removeButton.imagePosition = .imageOnly
        removeButton.contentTintColor = NSColor(white: 0.35, alpha: 1)
        removeButton.hoverColor = NSColor.black.withAlphaComponent(0.08)
        removeButton.layer?.cornerRadius = 8
        removeButton.toolTip = "Remove the image and its text"
        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.alphaValue = 0 // shows on hover

        for view in [thumbnail, label, removeButton] { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            thumbnail.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            thumbnail.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 26),
            thumbnail.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 2),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { setRemoveVisible(true) }
    override func mouseExited(with event: NSEvent) { setRemoveVisible(false) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.arrow.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onOpen?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onOpen?()
        return true
    }

    private func setRemoveVisible(_ visible: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            removeButton.animator().alphaValue = visible ? 1 : 0
        }
    }

    @objc private func removeClicked() { onRemove?() }
}

// MARK: - Screen dimmer

/// Small rounded label used for the "Drag to take a screenshot" hint and the
/// selection size readout on the dimmed backdrop.
private final class Badge: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon: NSImageView?

    init(symbol: String?, dark: Bool) {
        icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }.map { NSImageView(image: $0) }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = (dark ? NSColor(white: 0.08, alpha: 0.9) : NSColor.white).cgColor
        layer?.borderWidth = dark ? 0 : 0.5
        layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor
        let color = dark ? NSColor.white : NSColor(white: 0.12, alpha: 1)
        label.font = .systemFont(ofSize: 12, weight: dark ? .medium : .regular)
        label.textColor = color
        icon?.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        icon?.contentTintColor = color
        let stack = NSStackView(views: [icon, label].compactMap { $0 })
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 7, bottom: 3, right: 7)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(_ text: String) {
        label.stringValue = text
        setFrameSize(fittingSize)
    }
}

/// The dimmed backdrop itself. Normally a click reports `onClick` (close).
/// With `selectionEnabled` (screenshot mode) the mouse selects a piece of the
/// screen instead — drag it out, or click a corner, move, and click the other
/// one: the dim opens a clear hole with a white outline and a size readout,
/// and a hint follows the crosshair cursor. A right click reports `onClick`.
final class ScreenSelectionView: NSView {
    var onClick: (() -> Void)?
    /// The selection, in global screen coordinates (bottom-left origin).
    var onSelect: ((NSRect) -> Void)?

    var selectionEnabled = false {
        didSet {
            dragStart = nil
            clickAnchored = false
            selection = nil
            hint.isHidden = true
            sizeBadge.isHidden = true
        }
    }

    /// A click (no drag) set the first corner; the rect follows the mouse until
    /// the next click.
    private var clickAnchored = false

    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let hint = Badge(symbol: "crop", dark: false)
    private let sizeBadge = Badge(symbol: nil, dark: true)
    private var dragStart: NSPoint?
    private var selection: NSRect? { didSet { updateLayers() } }
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        dim.fillColor = NSColor.black.withAlphaComponent(0.16).cgColor
        dim.fillRule = .evenOdd
        outline.fillColor = nil
        outline.strokeColor = NSColor.white.cgColor
        outline.lineWidth = 1.5
        layer?.addSublayer(dim)
        layer?.addSublayer(outline)
        hint.setText("Select the text to translate · Esc to cancel")
        addSubview(hint)
        addSubview(sizeBadge)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        updateLayers()
    }

    // The window gets resized to each screen it dims; don't wait for a layout
    // pass to size the dim, or it stays empty (and clicks fall through).
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayers()
    }

    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let full = convertToLayer(bounds)
        dim.frame = full
        outline.frame = full
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: full.size))
        if let selection {
            let hole = convertToLayer(selection).offsetBy(dx: -full.minX, dy: -full.minY)
            path.addRect(hole)
            outline.path = CGPath(rect: hole.insetBy(dx: -0.75, dy: -0.75), transform: nil)
        } else {
            outline.path = nil
        }
        dim.path = path
        CATransaction.commit()
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard selectionEnabled else { return }
        NSCursor.crosshair.set()
        let point = convert(event.locationInWindow, from: nil)
        if clickAnchored {
            stretchSelection(to: point)
            return
        }
        guard dragStart == nil else { return }
        hint.setFrameOrigin(NSPoint(x: point.x + 14, y: point.y - hint.frame.height - 14))
        hint.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        hint.isHidden = true
        if selectionEnabled { NSCursor.arrow.set() }
    }

    override func mouseDown(with event: NSEvent) {
        DebugLog.log("backdrop: mouseDown (selectionEnabled=\(selectionEnabled) anchored=\(clickAnchored))")
        guard selectionEnabled else { return }
        guard !clickAnchored else { return } // the closing click — handled on mouse-up
        dragStart = convert(event.locationInWindow, from: nil)
        selection = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard selectionEnabled else { return }
        stretchSelection(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionEnabled else {
            onClick?() // normal mode: a click on the backdrop closes the widget
            return
        }
        if selection == nil, !clickAnchored, dragStart != nil {
            // A click without a drag: that's the first corner; the next click ends it.
            clickAnchored = true
            hint.isHidden = true
            return
        }
        let finished = selection
        DebugLog.log("backdrop: selection done (\(finished.map { "\(Int($0.width))×\(Int($0.height))" } ?? "none"))")
        dragStart = nil
        clickAnchored = false
        selection = nil
        sizeBadge.isHidden = true
        guard let finished, finished.width >= 8, finished.height >= 8, let window else { return } // too small — start over
        onSelect?(window.convertToScreen(convert(finished, to: nil)))
    }

    override func rightMouseDown(with event: NSEvent) { onClick?() }

    /// Grows the selection from the first corner to `point` (drag or anchored move).
    private func stretchSelection(to point: NSPoint) {
        guard let start = dragStart else { return }
        let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        guard selection != nil || rect.width > 3 || rect.height > 3 else { return } // not moved enough yet
        selection = rect
        hint.isHidden = true
        sizeBadge.setText("\(Int(rect.width)) × \(Int(rect.height))")
        sizeBadge.setFrameOrigin(NSPoint(x: rect.minX, y: max(rect.minY - sizeBadge.frame.height - 6, 4)))
        sizeBadge.isHidden = false
    }
}

/// Full-screen dimmed backdrop placed just below the panel. It swallows the
/// click that dismisses the panel (so it doesn't leak to the app underneath)
/// and, in screenshot mode, is where the piece of screen gets selected.
final class DimWindow: NSWindow {
    let selectionView = ScreenSelectionView()
    /// In screenshot mode the backdrop is the only window up, so it takes the
    /// keyboard (for Esc).
    var acceptsKey = false

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        // The selection view draws the dim (with a hole while selecting). The
        // all-but-invisible fill makes sure the window always catches clicks —
        // macOS lets clicks through fully transparent windows.
        backgroundColor = NSColor.black.withAlphaComponent(0.002)
        hasShadow = false
        ignoresMouseEvents = false
        isReleasedWhenClosed = false
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        alphaValue = 0
        contentView = selectionView
    }

    override var canBecomeKey: Bool { acceptsKey }
    override var canBecomeMain: Bool { false }
}
