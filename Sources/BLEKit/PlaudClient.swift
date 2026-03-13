/// High-level BLE client for PLAUD Note — actor with CoreBluetooth delegate bridge.
///
/// Ported from Python CLI `src/plaude/ble/client.py`.

import CoreBluetooth
import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "ble")

/// Errors from BLE communication, classified by failure type.
public enum BLEError: Error, LocalizedError {
    // Connection phase
    case bluetoothOff
    case bluetoothUnauthorized
    case deviceNotFound
    case connectionFailed(Error?)
    case disconnected

    // Service discovery
    case serviceNotFound
    case characteristicsNotFound

    // Protocol
    case notConnected
    case handshakeFailed
    case timeout(String)
    case transferRejected(UInt8)
    case noResponse(String)

    public var errorDescription: String? {
        switch self {
        case .bluetoothOff: return "Bluetooth is turned off"
        case .bluetoothUnauthorized: return "Bluetooth permission not granted — check System Settings > Privacy"
        case .deviceNotFound: return "PLAUD device not found — ensure it is nearby and powered on"
        case .connectionFailed(let err):
            if let err { return "Connection failed: \(err.localizedDescription)" }
            return "Connection to device failed"
        case .disconnected: return "Device disconnected unexpectedly"
        case .serviceNotFound: return "PLAUD BLE service not found — device may need a firmware update"
        case .characteristicsNotFound: return "BLE characteristics missing — protocol mismatch with device"
        case .notConnected: return "Not connected to device"
        case .handshakeFailed: return "Handshake failed — check token or ensure device is not recording"
        case .timeout(let msg): return "Timeout: \(msg)"
        case .transferRejected(let s): return "Transfer rejected by device (status=\(s))"
        case .noResponse(let msg): return "No response: \(msg)"
        }
    }
}

/// High-level BLE client for PLAUD Note.
///
/// Uses an actor for thread safety. CoreBluetooth delegates forward events
/// to the actor via `Task { await actor.handle(...) }`.
public actor PlaudClient {
    private let address: String
    private let token: String

    private let delegate: ClientDelegate
    private var centralManager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var txCharacteristic: CBCharacteristic?
    private var rxCharacteristic: CBCharacteristic?

    // Response multiplexing: one continuation per command ID
    private var pendingResponses: [UInt16: CheckedContinuation<Data?, Never>] = [:]

    // Voice data accumulation
    public private(set) var voiceData = Data()
    public private(set) var voicePacketCount = 0
    public var isReceiving = false
    public private(set) var isConnected = false

    public init(address: String, token: String) {
        self.address = address
        self.token = token
        self.delegate = ClientDelegate()
    }

    // MARK: - Connection

    public func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.configure(actor: self, connectContinuation: continuation, address: address)
            let cm = CBCentralManager(delegate: delegate, queue: delegate.queue)
            self.centralManager = cm
        }
        isConnected = true
    }

    public func disconnect() async {
        if let peripheral, let cm = centralManager {
            cm.cancelPeripheralConnection(peripheral)
        }
        isConnected = false
    }

    // MARK: - Commands

    /// Authenticate with the device using the binding token.
    public func handshake() async throws -> Bool {
        var tokenBytes = Data(token.utf8.prefix(32))
        while tokenBytes.count < 32 { tokenBytes.append(0) }
        let payload = Data([0x02, 0x00, 0x00]) + tokenBytes

        try await send(cmdHandshake, payload: payload)
        guard let resp = await waitResponse(cmdHandshake, timeout: 5.0),
              !resp.isEmpty else { return false }

        return resp[0] == 0
    }

    /// Sync current time to the device.
    public func timeSync() async throws {
        var ts = UInt32(Date().timeIntervalSince1970).littleEndian
        let payload = Data(bytes: &ts, count: 4)
        try await send(cmdTimeSync, payload: payload)
        _ = await waitResponse(cmdTimeSync, timeout: 3.0)
    }

    /// Retrieve the list of recording sessions from the device.
    public func getSessions() async throws -> [RecordingSession] {
        try await send(cmdGetRecSessions)
        guard let resp = await waitResponse(cmdGetRecSessions, timeout: 5.0) else {
            return []
        }
        return parseSessions(resp)
    }

    // MARK: - Low-level Send/Receive

    public func send(_ cmdID: UInt16, payload: Data = Data()) async throws {
        guard let rx = rxCharacteristic, let p = peripheral else {
            throw BLEError.notConnected
        }
        let pkt = buildCmd(cmdID, payload: payload)
        let name = cmdNames[cmdID] ?? "CMD_\(cmdID)"
        log.debug("-> [\(name, privacy: .public)] \(pkt.prefix(40).hexString, privacy: .public)")
        p.writeValue(pkt, for: rx, type: .withResponse)
    }

    public func waitResponse(_ cmdID: UInt16, timeout: TimeInterval = 5.0) async -> Data? {
        await withCheckedContinuation { continuation in
            pendingResponses[cmdID] = continuation

            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = pendingResponses.removeValue(forKey: cmdID) {
                    c.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Voice Buffer

    public func resetVoiceBuffer() {
        voiceData = Data()
        voicePacketCount = 0
    }

    public func setReceiving(_ value: Bool) {
        isReceiving = value
    }

    // MARK: - Delegate Callbacks (called from delegate bridge)

    func handleCommandResponse(cmdID: UInt16, payload: Data) {
        let name = cmdNames[cmdID] ?? "CMD_\(cmdID)"
        log.debug("<- [\(name, privacy: .public)] \(payload.prefix(40).hexString, privacy: .public)")
        if let continuation = pendingResponses.removeValue(forKey: cmdID) {
            continuation.resume(returning: payload)
        }
    }

    func handleVoiceData(_ data: Data) {
        if isReceiving {
            voiceData.append(data)
            voicePacketCount += 1
        }
    }

    func setPeripheral(_ p: CBPeripheral) { peripheral = p }
    func setTxCharacteristic(_ c: CBCharacteristic) { txCharacteristic = c }
    func setRxCharacteristic(_ c: CBCharacteristic) { rxCharacteristic = c }
}

// MARK: - CoreBluetooth Delegate Bridge

private final class ClientDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.openplaudit.ble")

    private weak var actor: PlaudClient?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var targetAddress: String = ""
    private var discoveredPeripheral: CBPeripheral?

    private let plaudServiceCBUUID = CBUUID(string: serviceUUID)
    private let txCBUUID = CBUUID(string: txUUID)
    private let rxCBUUID = CBUUID(string: rxUUID)

    func configure(actor: PlaudClient, connectContinuation: CheckedContinuation<Void, Error>, address: String) {
        self.actor = actor
        self.connectContinuation = connectContinuation
        self.targetAddress = address.uppercased()
    }

    // MARK: - Central Manager

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(
                withServices: [plaudServiceCBUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .poweredOff:
            connectContinuation?.resume(throwing: BLEError.bluetoothOff)
            connectContinuation = nil
        case .unauthorized:
            connectContinuation?.resume(throwing: BLEError.bluetoothUnauthorized)
            connectContinuation = nil
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Match by UUID (macOS uses UUIDs, not MAC addresses)
        let id = peripheral.identifier.uuidString.uppercased()
        guard id == targetAddress || peripheral.name?.lowercased().contains("plaud") == true else { return }

        central.stopScan()
        discoveredPeripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([plaudServiceCBUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: BLEError.connectionFailed(error))
        connectContinuation = nil
    }

    // MARK: - Peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == plaudServiceCBUUID }) else {
            connectContinuation?.resume(throwing: BLEError.serviceNotFound)
            connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([txCBUUID, rxCBUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else {
            connectContinuation?.resume(throwing: BLEError.characteristicsNotFound)
            connectContinuation = nil
            return
        }

        let actor = self.actor!
        var txChar: CBCharacteristic?
        var rxChar: CBCharacteristic?

        for c in chars {
            if c.uuid == txCBUUID {
                peripheral.setNotifyValue(true, for: c)
                txChar = c
            } else if c.uuid == rxCBUUID {
                rxChar = c
            }
        }

        // Use nonisolated(unsafe) to cross isolation boundary —
        // safe because CB delegates are called on our serial queue
        nonisolated(unsafe) let sendPeripheral = peripheral
        nonisolated(unsafe) let sendTx = txChar
        nonisolated(unsafe) let sendRx = rxChar
        let continuation = self.connectContinuation
        self.connectContinuation = nil

        Task {
            if let tx = sendTx { await actor.setTxCharacteristic(tx) }
            if let rx = sendRx { await actor.setRxCharacteristic(rx) }
            await actor.setPeripheral(sendPeripheral)
            continuation?.resume(returning: ())
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value, !data.isEmpty else { return }
        let proto = data[0]

        if proto == protoVoice {
            let voicePayload = data.dropFirst()
            Task { await actor?.handleVoiceData(Data(voicePayload)) }
            return
        }

        guard proto == protoCommand, data.count >= 3 else { return }
        let cmdID = data.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt16.self).littleEndian
        }
        let payload = Data(data.dropFirst(3))
        Task { await actor?.handleCommandResponse(cmdID: cmdID, payload: payload) }
    }
}

// MARK: - Data Hex String

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
