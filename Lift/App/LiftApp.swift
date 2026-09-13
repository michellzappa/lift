import AppKit
import HouseKit

@main
@MainActor
final class LiftAppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = LiftStore()
    private let desk = DeskController()
    private let sitHotkey = GlobalHotkey(signature: "LIFT", id: 1)
    private let standHotkey = GlobalHotkey(signature: "LIFT", id: 2)
    private lazy var settingsWindowController = SettingsWindowController.lift(store: store, desk: desk)
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!

    static func main() {
        let application = NSApplication.shared
        let delegate = LiftAppDelegate()
        application.delegate = delegate
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApplication.shared.mainMenu = makeMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuBarPlate.image(glyph: HouseGlyphs.lift)
            button.imagePosition = .imageOnly
            button.setAccessibilityLabel("Lift menu")
            button.toolTip = "Lift"
        }
        statusMenu = NSMenu()
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        rebuildStatusMenu()

        desk.preferredIdentifier = store.settings.deskIdentifier
        desk.onPaired = { [store] id, name in store.update { $0.deskIdentifier = id; $0.deskName = name } }
        sitHotkey.onPress = { [weak self] in self?.sit(nil) }
        standHotkey.onPress = { [weak self] in self?.stand(nil) }
        applySettings()
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange), name: LiftStore.didChange, object: store)
        NotificationCenter.default.addObserver(self, selector: #selector(deskDidChange), name: DeskController.didChange, object: desk)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "lift" {
            switch url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) {
            case "sit": sit(nil)
            case "stand": stand(nil)
            case "toggle": toggle(nil)
            case "settings": settingsWindowController.show()
            default: break
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { settingsWindowController.show() }
        return true
    }

    @objc private func settingsDidChange() { applySettings() }
    @objc private func deskDidChange() { statusItem.button?.toolTip = headerText }

    private func applySettings() {
        let settings = store.settings
        sitHotkey.register(settings.sitHotkey)
        standHotkey.register(settings.standHotkey)
        statusItem.isVisible = settings.showMenuBarIcon
        if LaunchAtLogin.isEnabled != settings.launchAtLogin {
            try? LaunchAtLogin.setEnabled(settings.launchAtLogin)
        }
    }

    // MARK: - Status menu

    private var headerText: String {
        guard desk.isConnected else { return desk.status.label }
        guard let height = desk.height else { return "Reading height…" }
        let posture: String
        if desk.isMoving { posture = "Moving" }
        else if abs(height - store.settings.standHeight) < 1.5 { posture = "Standing" }
        else if abs(height - store.settings.sitHeight) < 1.5 { posture = "Sitting" }
        else { posture = desk.status.label }
        return "\(Self.format(height)) · \(posture)"
    }

    static func format(_ centimetres: Double) -> String {
        String(format: "%.1f cm", centimetres)
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        statusMenu.addItem(StatusMenu.sectionHeader(headerText))
        let settings = store.settings
        let connected = desk.isConnected

        let sitItem = NSMenuItem(title: "Sit  (\(Self.format(settings.sitHeight)))", action: #selector(sit(_:)), keyEquivalent: "")
        if let (key, mods) = settings.sitHotkey?.menuKeyEquivalent { sitItem.keyEquivalent = key; sitItem.keyEquivalentModifierMask = mods }
        let standItem = NSMenuItem(title: "Stand  (\(Self.format(settings.standHeight)))", action: #selector(stand(_:)), keyEquivalent: "")
        if let (key, mods) = settings.standHotkey?.menuKeyEquivalent { standItem.keyEquivalent = key; standItem.keyEquivalentModifierMask = mods }
        let upItem = NSMenuItem(title: "Nudge Up", action: #selector(nudgeUp(_:)), keyEquivalent: "")
        let downItem = NSMenuItem(title: "Nudge Down", action: #selector(nudgeDown(_:)), keyEquivalent: "")
        let stopItem = NSMenuItem(title: "Stop", action: #selector(stopDesk(_:)), keyEquivalent: ".")
        stopItem.isEnabled = desk.isMoving
        for item in [sitItem, standItem, upItem, downItem] { item.isEnabled = connected }
        statusMenu.items += [sitItem, standItem, .separator(), upItem, downItem, stopItem, .separator()]

        let saveSit = NSMenuItem(title: "Save Current as Sit Height", action: #selector(saveSit(_:)), keyEquivalent: "")
        let saveStand = NSMenuItem(title: "Save Current as Stand Height", action: #selector(saveStand(_:)), keyEquivalent: "")
        saveSit.isEnabled = desk.height != nil
        saveStand.isEnabled = desk.height != nil
        statusMenu.items += [saveSit, saveStand]
        if !connected {
            statusMenu.addItem(.separator())
            statusMenu.addItem(NSMenuItem(title: "Reconnect", action: #selector(reconnect(_:)), keyEquivalent: "r"))
        }
        statusMenu.items.forEach { $0.target = self }
        StatusMenu.appendStandardTail(
            to: statusMenu,
            appName: "Lift",
            target: self,
            settings: #selector(showSettings(_:)),
            launchAtLogin: #selector(toggleLaunchAtLogin(_:)),
            launchAtLoginEnabled: settings.launchAtLogin,
            quit: #selector(quit(_:))
        )
    }

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()
        let appMenu = NSMenu(title: "Lift")
        appMenu.addItem(withTitle: "About Lift", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lift", action: #selector(quit(_:)), keyEquivalent: "q").target = self
        mainMenu.addItem(withTitle: "Lift", action: nil, keyEquivalent: "").submenu = appMenu
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        mainMenu.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu
        NSApplication.shared.windowsMenu = windowMenu
        return mainMenu
    }

    // MARK: - Actions

    @objc private func sit(_ sender: Any?) { desk.move(to: store.settings.sitHeight) }
    @objc private func stand(_ sender: Any?) { desk.move(to: store.settings.standHeight) }
    @objc private func toggle(_ sender: Any?) {
        guard let height = desk.height else { return }
        let settings = store.settings
        let closerToStand = abs(height - settings.standHeight) < abs(height - settings.sitHeight)
        desk.move(to: closerToStand ? settings.sitHeight : settings.standHeight)
    }
    @objc private func nudgeUp(_ sender: Any?) { desk.nudge(up: true) }
    @objc private func nudgeDown(_ sender: Any?) { desk.nudge(up: false) }
    @objc private func stopDesk(_ sender: Any?) { desk.stop() }
    @objc private func reconnect(_ sender: Any?) { desk.connect() }
    @objc private func saveSit(_ sender: Any?) {
        guard let height = desk.height else { return }
        store.update { $0.sitHeight = (height * 10).rounded() / 10 }
    }
    @objc private func saveStand(_ sender: Any?) {
        guard let height = desk.height else { return }
        store.update { $0.standHeight = (height * 10).rounded() / 10 }
    }
    @objc private func showSettings(_ sender: Any?) { settingsWindowController.show() }
    @objc private func toggleLaunchAtLogin(_ sender: Any?) { store.update { $0.launchAtLogin.toggle() } }
    @objc private func quit(_ sender: Any?) { NSApp.terminate(nil) }
}
