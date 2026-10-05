import Cocoa
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var contextMenu: NSMenu!
    private var openMenuItem: NSMenuItem!
    private var screenshotMenuItem: NSMenuItem!
    private var launchAtLoginItem: NSMenuItem!
    private let panelController = TranslatePanelController()
    private var preferences: PreferencesWindowController?
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)

        // DISABLED (paired with the live language-tracking in TranslatePanelController):
        // App Nap opt-out kept the background poll/notifications alive. Re-enable it
        // together with that subscription.
        /*
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Track macOS system-language changes live")
        */

        DebugLog.installCrashHandlers()
        SelectionReader.logTrust()
        AppSettings.migrateLegacyKeyIfNeeded()

        setupMainMenu() // enables standard ⌘A/⌘C/⌘V/⌘X/⌘Z in the text fields
        setupStatusItem()

        panelController.onOpenPreferences = { [weak self] in self?.openPreferences() }

        for manager in HotKeyManager.all {
            manager.onChange = { [weak self] in self?.refreshHotKeyLabel() }
        }
        HotKeyManager.shared.start { [weak self] in self?.panelController.toggleWithSelection() }
        HotKeyManager.screenshot.start { [weak self] in self?.panelController.startScreenshot() }

        // Launching the app (double-clicking its icon) opens the widget. Without
        // this the app would just sit silently in the menu bar and the icon would
        // appear to "do nothing".
        panelController.open()
    }

    /// Clicking the app icon (Finder / Launchpad / Dock) while it's already running
    /// re-opens the widget instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        panelController.open()
        return true
    }

    // MARK: - Menu bar

    /// A minimal Edit menu so standard editing shortcuts work in the text views.
    /// (LSUIElement apps still consult `NSApp.mainMenu` for key equivalents.)
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editItem.submenu = editMenu

        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            let globe = NSImage(systemSymbolName: "globe", accessibilityDescription: "Translator")?
                .withSymbolConfiguration(config)
            globe?.isTemplate = true // monochrome, adapts to the menu bar (ChatGPT-style)
            button.image = globe
            // Left click opens the widget; right click shows the menu.
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        contextMenu = NSMenu()

        openMenuItem = NSMenuItem(title: openTitle,
                                  action: #selector(togglePanel),
                                  keyEquivalent: "")
        openMenuItem.target = self
        contextMenu.addItem(openMenuItem)

        screenshotMenuItem = NSMenuItem(title: screenshotTitle,
                                        action: #selector(startScreenshot),
                                        keyEquivalent: "")
        screenshotMenuItem.target = self
        contextMenu.addItem(screenshotMenuItem)

        let prefsItem = NSMenuItem(title: "Settings…",
                                   action: #selector(openPreferences),
                                   keyEquivalent: ",")
        prefsItem.target = self
        contextMenu.addItem(prefsItem)

        launchAtLoginItem = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin),
                                       keyEquivalent: "")
        launchAtLoginItem.target = self
        contextMenu.addItem(launchAtLoginItem)

        // Keep the checkmark in sync with the real login-item state each time the menu opens.
        contextMenu.delegate = self

        contextMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit",
                                  action: #selector(quit),
                                  keyEquivalent: "q")
        quitItem.target = self
        contextMenu.addItem(quitItem)
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isRightClick {
            // Temporarily attach the menu so it pops up, then detach so the
            // next left click triggers the action again.
            statusItem.menu = contextMenu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            togglePanel()
        }
    }

    private var openTitle: String {
        "Open Translator  (\(HotKeyManager.shared.currentDisplayString))"
    }

    private var screenshotTitle: String {
        "Screenshot and Translate  (\(HotKeyManager.screenshot.currentDisplayString))"
    }

    private func refreshHotKeyLabel() {
        openMenuItem?.title = openTitle
        screenshotMenuItem?.title = screenshotTitle
    }

    // MARK: - Actions

    @objc private func startScreenshot() {
        panelController.startScreenshot()
    }

    @objc private func togglePanel() {
        panelController.toggle()
    }

    @objc private func openPreferences() {
        if preferences == nil {
            preferences = PreferencesWindowController()
        }
        NSApp.activate(ignoringOtherApps: true)
        preferences?.showWindow(nil)
        preferences?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Launch at login

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change “Launch at Login”"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        refreshLaunchAtLoginState()
    }

    private func refreshLaunchAtLoginState() {
        launchAtLoginItem?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        refreshLaunchAtLoginState()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
