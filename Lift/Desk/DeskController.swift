import CoreBluetooth
import Foundation

/// A Linak DPG desk (IKEA Idasen and friends) over Bluetooth LE.
///
/// Protocol, as reverse-engineered by the idasen / linak-controller projects:
/// - `99FA0002` control: `0x4700` up, `0x4600` down, `0xFF00` stop, `0xFE00` wake
/// - `99FA0021` height: `uint16` tenths of a millimetre above 62 cm, then speed
/// - `99FA0031` reference input: write the target height (same unit) repeatedly
///   while moving; the desk stops itself when it gets there.
@MainActor
final class DeskController: NSObject {
    static let didChange = Notification.Name("DeskController.didChange")

    enum Status: Equatable {
        case bluetoothOff, unauthorized, scanning, connecting(String), connected(String), disconnected
        var label: String {
            switch self {
            case .bluetoothOff: "Bluetooth is off"
            case .unauthorized: "Bluetooth access not granted"
            case .scanning: "Looking for a desk…"
            case .connecting(let name): "Connecting to \(name)…"
            case .connected(let name): name
            case .disconnected: "Not connected"
            }
        }
    }

    private(set) var status: Status = .disconnected { didSet { changed() } }
    /// Centimetres, or nil until the first reading.
    private(set) var height: Double? { didSet { changed() } }
    private(set) var isMoving = false { didSet { changed() } }
    var isConnected: Bool { if case .connected = status { true } else { false } }

    /// Set by the app: which desk to prefer, and where to remember a new one.
    var preferredIdentifier: UUID?
    var onPaired: (UUID, String) -> Void = { _, _ in }

    private static let controlService = CBUUID(string: "99FA0001-338A-1024-8A49-009C0215F78A")
    private static let controlCharacteristic = CBUUID(string: "99FA0002-338A-1024-8A49-009C0215F78A")
    private static let heightService = CBUUID(string: "99FA0020-338A-1024-8A49-009C0215F78A")
    private static let heightCharacteristic = CBUUID(string: "99FA0021-338A-1024-8A49-009C0215F78A")
    private static let referenceService = CBUUID(string: "99FA0030-338A-1024-8A49-009C0215F78A")
    private static let referenceCharacteristic = CBUUID(string: "99FA0031-338A-1024-8A49-009C0215F78A")
    private static let baseHeightCentimetres: Double = 62

    private var central: CBCentralManager!
    private var desk: CBPeripheral?
    private var control: CBCharacteristic?
    private var reference: CBCharacteristic?
    private var moveTask: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    static var authorization: CBManagerAuthorization { CBManager.authorization }

    // MARK: - Connection

    func connect() {
        guard central.state == .poweredOn else { return }
        if let desk { central.cancelPeripheralConnection(desk) }
        desk = nil
        control = nil
        reference = nil
        if let preferredIdentifier,
           let known = central.retrievePeripherals(withIdentifiers: [preferredIdentifier]).first {
            connect(to: known)
            return
        }
        status = .scanning
        central.scanForPeripherals(withServices: [Self.controlService])
    }

    /// Drop the remembered desk and look for any desk in range.
    func forget() {
        preferredIdentifier = nil
        connect()
    }

    private func connect(to peripheral: CBPeripheral) {
        central.stopScan()
        desk = peripheral
        peripheral.delegate = self
        status = .connecting(peripheral.name ?? "desk")
        central.connect(peripheral)
    }

    // MARK: - Movement

    func move(to targetCentimetres: Double) {
        guard let desk, let control, let reference, isConnected else { return }
        let target = min(max(targetCentimetres, LiftSettings.minimumHeight), LiftSettings.maximumHeight)
        moveTask?.cancel()
        moveTask = Task { @MainActor [weak self] in
            guard let self else { return }
            isMoving = true
            defer { isMoving = false }
            desk.writeValue(Data([0xFE, 0x00]), for: control, type: .withoutResponse)
            let encoded = UInt16(((target - Self.baseHeightCentimetres) * 100).rounded())
            let payload = Data([UInt8(encoded & 0xFF), UInt8(encoded >> 8)])
            let deadline = Date().addingTimeInterval(25)
            while !Task.isCancelled, Date() < deadline {
                if let height, abs(height - target) < 0.3 { break }
                desk.writeValue(payload, for: reference, type: .withoutResponse)
                try? await Task.sleep(for: .milliseconds(200))
            }
            desk.writeValue(Data([0xFF, 0x00]), for: control, type: .withoutResponse)
        }
    }

    /// One short pulse in a direction; the desk moves roughly a centimetre.
    func nudge(up: Bool) {
        guard let desk, let control, isConnected else { return }
        moveTask?.cancel()
        desk.writeValue(Data([up ? 0x47 : 0x46, 0x00]), for: control, type: .withoutResponse)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            desk.writeValue(Data([0xFF, 0x00]), for: control, type: .withoutResponse)
        }
    }

    func stop() {
        moveTask?.cancel()
        guard let desk, let control else { return }
        desk.writeValue(Data([0xFF, 0x00]), for: control, type: .withoutResponse)
    }

    private func changed() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

// CoreBluetooth calls back on the queue we gave it (main), which the compiler
// cannot see; assume the isolation we arranged.
extension DeskController: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        nonisolated(unsafe) let central = central
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: connect()
            case .unauthorized: status = .unauthorized
            case .poweredOff: status = .bluetoothOff
            default: status = .disconnected
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            guard desk == nil else { return }
            connect(to: peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            peripheral.discoverServices([Self.controlService, Self.heightService, Self.referenceService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            status = .disconnected
            desk = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        nonisolated(unsafe) let central = central
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            status = .disconnected
            height = nil
            control = nil
            reference = nil
            // Desks sleep; come back when they wake.
            central.connect(peripheral)
            status = .connecting(peripheral.name ?? "desk")
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            for service in peripheral.services ?? [] {
                peripheral.discoverCharacteristics(nil, for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: (any Error)?) {
        nonisolated(unsafe) let peripheral = peripheral
        nonisolated(unsafe) let service = service
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                switch characteristic.uuid {
                case Self.controlCharacteristic: control = characteristic
                case Self.referenceCharacteristic: reference = characteristic
                case Self.heightCharacteristic:
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                default: break
                }
            }
            if control != nil, reference != nil, !isConnected {
                let name = peripheral.name ?? "Desk"
                status = .connected(name)
                if preferredIdentifier != peripheral.identifier {
                    preferredIdentifier = peripheral.identifier
                    onPaired(peripheral.identifier, name)
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        nonisolated(unsafe) let characteristic = characteristic
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.heightCharacteristic, let data = characteristic.value, data.count >= 2 else { return }
            let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
            height = Self.baseHeightCentimetres + Double(raw) / 100
        }
    }
}
