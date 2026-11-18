import CoreBluetooth
import Foundation

/// A Linak DPG desk (IKEA Idasen and friends) over Bluetooth LE.
///
/// Protocol, as reverse-engineered by the idasen / linak-controller projects:
/// - `99FA0002` control: `0x4700` up, `0x4600` down, `0xFF00` stop, `0xFE00` wake
/// - `99FA0021` height: `uint16` tenths of a millimetre above 62 cm, then speed
/// - `99FA0031` reference input: write the target height (same unit) repeatedly
///   while moving; `0x0180` releases reference-input mode.
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
    private static let controlFeedbackCharacteristic = CBUUID(string: "99FA0003-338A-1024-8A49-009C0215F78A")
    private static let dpgService = CBUUID(string: "99FA0010-338A-1024-8A49-009C0215F78A")
    private static let dpgCharacteristic = CBUUID(string: "99FA0011-338A-1024-8A49-009C0215F78A")
    private static let heightService = CBUUID(string: "99FA0020-338A-1024-8A49-009C0215F78A")
    private static let heightCharacteristic = CBUUID(string: "99FA0021-338A-1024-8A49-009C0215F78A")
    private static let referenceService = CBUUID(string: "99FA0030-338A-1024-8A49-009C0215F78A")
    private static let referenceCharacteristic = CBUUID(string: "99FA0031-338A-1024-8A49-009C0215F78A")
    private static let dpiService = CBUUID(string: "99FA0050-338A-1024-8A49-009C0215F78A")
    private static let dpiCharacteristic = CBUUID(string: "99FA0051-338A-1024-8A49-009C0215F78A")
    private static let baseHeightCentimetres: Double = 62
    private static let wakeCommand = Data([0xFE, 0x00])
    private static let stopCommand = Data([0xFF, 0x00])
    private static let referenceInputStopCommand = Data([0x01, 0x80])

    private var central: CBCentralManager!
    private var desk: CBPeripheral?
    private var control: CBCharacteristic?
    private var dpg: CBCharacteristic?
    private var reference: CBCharacteristic?
    private var moveTask: Task<Void, Never>?
    private var movementGeneration = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    static var authorization: CBManagerAuthorization { CBManager.authorization }

    // MARK: - Connection

    func connect() {
        guard central.state == .poweredOn else { return }
        if let desk, let control {
            stopReferenceInput(on: desk, control: control, reference: reference)
        }
        movementGeneration += 1
        moveTask?.cancel()
        moveTask = nil
        isMoving = false
        if let desk { central.cancelPeripheralConnection(desk) }
        desk = nil
        control = nil
        dpg = nil
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
        let generation = beginMovement()
        moveTask = Task { @MainActor [weak self] in
            guard let self, generation == movementGeneration, !Task.isCancelled else { return }
            isMoving = true
            defer {
                if generation == movementGeneration {
                    isMoving = false
                    moveTask = nil
                }
            }

            prepareForReferenceInput(on: desk, control: control, reference: reference)
            let encoded = UInt16(((target - Self.baseHeightCentimetres) * 100).rounded())
            let payload = Data([UInt8(encoded & 0xFF), UInt8(encoded >> 8)])
            let deadline = Date().addingTimeInterval(25)
            while !Task.isCancelled, Date() < deadline {
                if let height, abs(height - target) < 0.3 { break }
                write(payload, to: reference, on: desk)
                try? await Task.sleep(for: .milliseconds(200))
            }
            if generation == movementGeneration {
                stopReferenceInput(on: desk, control: control, reference: reference)
            }
        }
    }

    /// One short pulse in a direction; the desk moves roughly a centimetre.
    func nudge(up: Bool) {
        guard let desk, let control, let reference, isConnected else { return }
        let generation = beginMovement()
        moveTask = Task { @MainActor [weak self] in
            guard let self, generation == movementGeneration, !Task.isCancelled else { return }
            isMoving = true
            prepareForReferenceInput(on: desk, control: control, reference: reference)
            write(Data([up ? 0x47 : 0x46, 0x00]), to: control, on: desk)
            try? await Task.sleep(for: .milliseconds(400))
            if generation == movementGeneration {
                stopReferenceInput(on: desk, control: control, reference: reference)
                isMoving = false
                moveTask = nil
            }
        }
    }

    func stop() {
        movementGeneration += 1
        moveTask?.cancel()
        moveTask = nil
        isMoving = false
        guard let desk, let control else { return }
        stopReferenceInput(on: desk, control: control, reference: reference)
    }

    private func beginMovement() -> Int {
        movementGeneration += 1
        moveTask?.cancel()
        return movementGeneration
    }

    /// The controller ignores reference-input writes until it has been woken
    /// and the previous command mode has been stopped. DPG panels also need
    /// their small initialization handshake after a fresh BLE connection.
    private func prepareForReferenceInput(on peripheral: CBPeripheral, control: CBCharacteristic, reference: CBCharacteristic) {
        if let dpg {
            write(Data([0x7F, 0x86, 0x00]), to: dpg, on: peripheral)
            write(Data([0x7F, 0x86, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10, 0x11]), to: dpg, on: peripheral)
        }
        write(Self.wakeCommand, to: control, on: peripheral)
        write(Self.stopCommand, to: control, on: peripheral)
        write(Self.referenceInputStopCommand, to: reference, on: peripheral)
    }

    private func stopReferenceInput(on peripheral: CBPeripheral, control: CBCharacteristic, reference: CBCharacteristic?) {
        write(Self.stopCommand, to: control, on: peripheral)
        if let reference {
            write(Self.referenceInputStopCommand, to: reference, on: peripheral)
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) {
        let type: CBCharacteristicWriteType
        if characteristic.properties.contains(.writeWithoutResponse) {
            type = .withoutResponse
        } else if characteristic.properties.contains(.write) {
            type = .withResponse
        } else {
            return
        }
        peripheral.writeValue(data, for: characteristic, type: type)
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
            peripheral.discoverServices([Self.controlService, Self.dpgService, Self.heightService, Self.referenceService, Self.dpiService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: (any Error)?) {
        MainActor.assumeIsolated {
            movementGeneration += 1
            moveTask?.cancel()
            moveTask = nil
            isMoving = false
            status = .disconnected
            desk = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: (any Error)?) {
        nonisolated(unsafe) let central = central
        nonisolated(unsafe) let peripheral = peripheral
        MainActor.assumeIsolated {
            movementGeneration += 1
            moveTask?.cancel()
            moveTask = nil
            isMoving = false
            status = .disconnected
            height = nil
            control = nil
            dpg = nil
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
                case Self.dpgCharacteristic:
                    dpg = characteristic
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                case Self.referenceCharacteristic: reference = characteristic
                case Self.heightCharacteristic:
                    peripheral.setNotifyValue(true, for: characteristic)
                    peripheral.readValue(for: characteristic)
                case Self.controlFeedbackCharacteristic:
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                case Self.dpiCharacteristic:
                    if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                default: break
                }
            }
            if let control, let reference, !isConnected {
                let name = peripheral.name ?? "Desk"
                status = .connected(name)
                if preferredIdentifier != peripheral.identifier {
                    preferredIdentifier = peripheral.identifier
                    onPaired(peripheral.identifier, name)
                }
                // Release any reference-input session left behind by a prior
                // connection so the desk's physical controls remain usable.
                stopReferenceInput(on: peripheral, control: control, reference: reference)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: (any Error)?) {
        nonisolated(unsafe) let characteristic = characteristic
        MainActor.assumeIsolated {
            guard characteristic.uuid == Self.heightCharacteristic, let data = characteristic.value, data.count >= 2 else { return }
            let raw = UInt16(data[0]) | (UInt16(data[1]) << 8)
            height = Self.baseHeightCentimetres + Double(raw) / 100
            if data.count >= 4 {
                let rawSpeed = UInt16(data[2]) | (UInt16(data[3]) << 8)
                if rawSpeed != 0 {
                    isMoving = true
                } else if moveTask == nil {
                    isMoving = false
                }
            }
        }
    }
}
