import Carbon.HIToolbox
import Foundation
import HouseKit

struct LiftSettings: Codable, Equatable, Sendable {
    /// Heights in centimetres. Idasen travels 62–127 cm.
    var sitHeight: Double = 72
    var standHeight: Double = 115
    var sitHotkey: KeyBinding? = KeyBinding(keyCode: UInt16(kVK_DownArrow), modifiers: UInt(controlKey | optionKey))
    var standHotkey: KeyBinding? = KeyBinding(keyCode: UInt16(kVK_UpArrow), modifiers: UInt(controlKey | optionKey))
    /// The desk we paired with, so we reconnect to it and not the neighbour's.
    var deskIdentifier: UUID?
    var deskName: String?
    var launchAtLogin: Bool = false
    var showMenuBarIcon: Bool = true

    static let minimumHeight: Double = 62
    static let maximumHeight: Double = 127
    static let defaultsKey = "lift.settings"

    static func load(from defaults: UserDefaults = .standard) -> LiftSettings {
        guard let data = defaults.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(LiftSettings.self, from: data)
        else { return LiftSettings() }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

@MainActor
final class LiftStore {
    static let didChange = Notification.Name("LiftStore.didChange")

    var settings: LiftSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    init() {
        settings = LiftSettings.load()
    }

    func update(_ block: (inout LiftSettings) -> Void) {
        var next = settings
        block(&next)
        settings = next
    }
}
