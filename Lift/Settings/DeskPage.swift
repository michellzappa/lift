import AppKit
import CoreBluetooth
import HouseKit

extension SettingsWindowController {
    /// Desk · General · About.
    static func lift(store: LiftStore, desk: DeskController) -> SettingsWindowController {
        SettingsWindowController(appName: "Lift", pages: [
            SettingsPage("Desk", symbol: "table.furniture", controller: DeskPage(store: store, desk: desk)),
            SettingsPage("General", symbol: "gearshape", controller: GeneralPage(
                launchAtLogin: (get: { store.settings.launchAtLogin }, set: { value in store.update { $0.launchAtLogin = value } }),
                showMenuBarIcon: (get: { store.settings.showMenuBarIcon }, set: { value in store.update { $0.showMenuBarIcon = value } }),
                permissions: [PermissionRow(
                    title: "Bluetooth",
                    grantedText: "Granted",
                    missingText: "Not granted",
                    isGranted: { CBManager.authorization == .allowedAlways },
                    openSettings: {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )]
            )),
            SettingsPage("About", symbol: "info.circle", controller: AboutPage(
                appName: "Lift",
                tagline: "Sit. Stand. One key each.",
                links: [("GitHub", URL(string: "https://github.com/michellzappa/lift")!)]
            ))
        ])
    }
}

/// Connection, the two presets, their hotkeys.
@MainActor
final class DeskPage: SettingsForm {
    private let store: LiftStore
    private let desk: DeskController
    private let statusLabel = SettingsForm.label("")
    private let heightLabel = SettingsForm.label("")
    private lazy var forgetButton = SettingsForm.button("Forget Desk", target: self, action: #selector(forget))
    private lazy var reconnectButton = SettingsForm.button("Reconnect", target: self, action: #selector(reconnect))
    private var sitField: NSTextField!
    private var standField: NSTextField!

    init(store: LiftStore, desk: DeskController) {
        self.store = store
        self.desk = desk
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: DeskController.didChange, object: desk)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: LiftStore.didChange, object: store)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        section("Connection")
        row("Desk", [statusLabel, reconnectButton, forgetButton])
        row("Height", heightLabel)
        note("Lift looks for a Linak-based desk (IKEA Idasen and similar) and remembers the first one it pairs with.")

        section("Presets")
        sitField = heightField(store.settings.sitHeight)
        standField = heightField(store.settings.standHeight)
        row("Sit", [sitField, SettingsForm.label("cm"), useCurrent(#selector(useCurrentSit))])
        row("Stand", [standField, SettingsForm.label("cm"), useCurrent(#selector(useCurrentStand))])
        note("Idasen travels 62–127 cm. “Use current” copies the desk's height right now.")

        section("Shortcuts")
        let sit = ShortcutRecorder(binding: store.settings.sitHotkey) { [store] value in store.update { s in s.sitHotkey = value } }
        sit.requiresModifiers = true
        row("Sit", sit)
        let stand = ShortcutRecorder(binding: store.settings.standHotkey) { [store] value in store.update { s in s.standHotkey = value } }
        stand.requiresModifiers = true
        row("Stand", stand)
        note("lift://sit, lift://stand and lift://toggle do the same from Shortcuts or a keyboard macro.")
        refresh()
    }

    private func heightField(_ value: Double) -> NSTextField {
        let field = SettingsForm.textField(width: 70)
        field.alignment = .right
        field.formatter = {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            formatter.minimum = LiftSettings.minimumHeight as NSNumber
            formatter.maximum = LiftSettings.maximumHeight as NSNumber
            return formatter
        }()
        field.doubleValue = value
        field.target = self
        field.action = #selector(presetEdited(_:))
        return field
    }

    private func useCurrent(_ action: Selector) -> NSButton {
        SettingsForm.button("Use Current", target: self, action: action)
    }

    @objc private func refresh() {
        statusLabel.stringValue = desk.status.label
        statusLabel.textColor = desk.isConnected ? .labelColor : .systemOrange
        heightLabel.stringValue = desk.height.map(LiftAppDelegate.format) ?? "—"
        forgetButton.isEnabled = store.settings.deskIdentifier != nil
        reconnectButton.isHidden = desk.isConnected
        if !isEditing(sitField) { sitField.doubleValue = store.settings.sitHeight }
        if !isEditing(standField) { standField.doubleValue = store.settings.standHeight }
    }

    private func isEditing(_ field: NSTextField) -> Bool {
        guard let editor = field.currentEditor() else { return false }
        return view.window?.firstResponder === editor
    }

    @objc private func presetEdited(_ sender: NSTextField) {
        let value = min(max(sender.doubleValue, LiftSettings.minimumHeight), LiftSettings.maximumHeight)
        if sender === sitField { store.update { $0.sitHeight = value } } else { store.update { $0.standHeight = value } }
    }

    @objc private func useCurrentSit() {
        guard let height = desk.height else { return }
        store.update { $0.sitHeight = (height * 10).rounded() / 10 }
    }

    @objc private func useCurrentStand() {
        guard let height = desk.height else { return }
        store.update { $0.standHeight = (height * 10).rounded() / 10 }
    }

    @objc private func forget() {
        store.update { $0.deskIdentifier = nil; $0.deskName = nil }
        desk.forget()
    }

    @objc private func reconnect() { desk.connect() }
}
