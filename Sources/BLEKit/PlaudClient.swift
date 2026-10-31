/// High-level BLE client for PLAUD Note — actor with CoreBluetooth delegate bridge.
///
/// Ported from Python CLI `src/plaude/ble/client.py`.

import CoreBluetooth
import Foundation
import os
import PlaudCore

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
    private let credentials: DeviceCredentials?
    private var sessionCrypto: SessionCrypto?
    public private(set) var portVersion: UInt8 = 0
    public private(set) var ssn: String?

    private var assembler: V20Assembler?

    private var preHandshakeFrames: [Data] = []
    private var preHandshakeWaiters: [UInt16: CheckedContinuation<Data?, Never>] = [:]

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
    public private(set) var deviceName: String?

    public init(address: String, token: String,
                credentials: DeviceCredentials? = nil) {
        self.address = address
        self.token = token
        self.credentials = credentials
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
        if let creds = credentials {
            return try await v20Handshake(creds)
        }
        var tokenBytes = Data(token.utf8.prefix(32))
        while tokenBytes.count < 32 { tokenBytes.append(0) }
        let payload = Data([0x02, 0x00, 0x00]) + tokenBytes

        try await send(cmdHandshake, payload: payload)
        guard let resp = await waitResponse(cmdHandshake, timeout: 5.0),
              !resp.isEmpty else { return false }

        return resp[0] == 0
    }

    ///
    private func v20Handshake(_ creds: DeviceCredentials) async throws -> Bool {
        preHandshakeFrames.removeAll()

        for chunk in V20Auth.chunks(cmd: V20Auth.cmdPreHandshakeNew,
                                    data: creds.snSignature) {
            try await sendRaw(chunk)
        }
        guard await waitPreHandshake(V20Auth.cmdPreHandshakeConfirm, timeout: 10) != nil else {
            throw V20Auth.AuthError.noConfirm
        }

        for chunk in V20Auth.chunks(cmd: V20Auth.cmdSendRSAPubKey,
                                    data: Data(creds.rsaPublicKeyPEM.utf8)) {
            try await sendRaw(chunk)
        }

        let frames = await collectKeyMaterial(timeout: 15)
        let keys = try V20Auth.sessionKeys(fromChunks: frames,
                                           privateKeyPEM: creds.rsaPrivateKeyPEM)
        let crypto = SessionCrypto(keys: keys)
        sessionCrypto = crypto

        let payload = V20Auth.handshakePayload(token: token, portVersion: 20)
        let packet = try crypto.encrypt(V20Auth.buildCmd(cmdHandshake, payload: payload))
        try await sendRaw(packet)
        guard let resp = await waitResponse(cmdHandshake, timeout: 10) else {
            throw BLEError.handshakeFailed
        }
        guard let status = resp.first else { throw BLEError.handshakeFailed }
        guard status == 0 else {
            throw V20Auth.AuthError.handshakeRejected(status)
        }
        if resp.count > 2 {
            portVersion = resp[2]
        }

        if portVersion >= 20, let ssnFrame = await waitResponse(2, timeout: 5.0),
           ssnFrame.count > 3 {
            let bytes = ssnFrame.dropFirst(3).prefix { $0 != 0 }
            ssn = String(bytes: bytes, encoding: .ascii)
            if let ssn {
                let two = V20Auth.handshakePayload(token: token, portVersion: portVersion,
                                                   ssn: ssn)
                let sealed = try crypto.encrypt(V20Auth.buildCmd(cmdHandshake, payload: two))
                try await sendRaw(sealed)
            }
        }
        return true
    }

    private func waitPreHandshake(_ cmd: UInt16, timeout: TimeInterval) async -> Data? {
        await withCheckedContinuation { continuation in
            preHandshakeWaiters[cmd] = continuation
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if let c = preHandshakeWaiters.removeValue(forKey: cmd) {
                    c.resume(returning: nil)
                }
            }
        }
    }

    private func collectKeyMaterial(timeout: TimeInterval) async -> [Data] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let frames = preHandshakeFrames.filter {
                $0.count >= 4 && (UInt16($0[0]) | (UInt16($0[1]) << 8)) == V20Auth.cmdSendRSAPubKey
            }
            if let first = frames.first {
                let total = Int(first[2])
                let indices = Set(frames.map { Int($0[3]) })
                if total > 0 && indices.count >= total { return frames }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return preHandshakeFrames
    }

    func beginAssembly(_ a: V20Assembler) { assembler = a }
    func endAssembly() { assembler = nil }
    func assemblerState() -> V20Assembler? { assembler }
    func clearGap() { assembler?.clearGap() }

    func handleNotification(_ raw: Data) {
        var frame = raw
        if let crypto = sessionCrypto {
            guard let decrypted = try? crypto.decrypt(frame) else {
                log.error("decrypt failed for \(raw.count) byte frame")
                return
            }
            frame = decrypted
        }
        guard !frame.isEmpty else { return }

        if sessionCrypto == nil, frame.count >= 2 {
            let opcode = UInt16(frame[0]) | (UInt16(frame[1]) << 8)
            if opcode == V20Auth.cmdPreHandshakeConfirm || opcode == V20Auth.cmdSendRSAPubKey {
                if let waiter = preHandshakeWaiters.removeValue(forKey: opcode) {
                    waiter.resume(returning: frame)
                } else {
                    preHandshakeFrames.append(frame)
                }
                return
            }
        }

        if frame[0] == protoVoice {
            if assembler != nil {
                assembler?.consume(frame)
            } else {
                handleVoiceData(Data(frame.dropFirst()))
            }
            return
        }
        guard frame[0] == protoCommand, frame.count >= 3 else { return }
        let cmdID = UInt16(frame[1]) | (UInt16(frame[2]) << 8)
        handleCommandResponse(cmdID: cmdID, payload: Data(frame.dropFirst(3)))
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
        let plain = V20Auth.buildCmd(cmdID, payload: payload)
        let pkt: Data
        if let crypto = sessionCrypto {
            pkt = try crypto.encrypt(plain)
        } else {
            pkt = plain
        }
        let name = cmdNames[cmdID] ?? "CMD_\(cmdID)"
        log.debug("-> [\(name, privacy: .public)] \(pkt.prefix(40).hexString, privacy: .public)")
        p.writeValue(pkt, for: rx, type: .withResponse)
    }

    func sendRaw(_ data: Data) async throws {
        guard let rx = rxCharacteristic, let p = peripheral else {
            throw BLEError.notConnected
        }
        p.writeValue(data, for: rx, type: .withResponse)
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

    func setPeripheral(_ p: CBPeripheral) {
        peripheral = p
        deviceName = p.name
    }
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

    private var scanTimer: DispatchWorkItem?
    private var scanTimeoutTimer: DispatchWorkItem?
    private let nordicManufacturerID: UInt16 = 0x0059
    private let scanTimeout: TimeInterval = 15.0

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // First: scan by service UUID
            central.scanForPeripherals(
                withServices: [plaudServiceCBUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )

            // After half the timeout: fallback to broader scan (Nordic mfr data / name)
            let fallback = DispatchWorkItem { [weak self] in
                guard let self, self.discoveredPeripheral == nil else { return }
                central.stopScan()
                central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
            }
            scanTimer = fallback
            queue.asyncAfter(deadline: .now() + scanTimeout / 2, execute: fallback)

            // After full timeout: give up
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.discoveredPeripheral == nil else { return }
                central.stopScan()
                self.connectContinuation?.resume(throwing: BLEError.deviceNotFound)
                self.connectContinuation = nil
            }
            scanTimeoutTimer = timeout
            queue.asyncAfter(deadline: .now() + scanTimeout, execute: timeout)

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
        let id = peripheral.identifier.uuidString.uppercased()
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let mfrData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let mfrID = mfrData.flatMap { d -> UInt16? in
            guard d.count >= 2 else { return nil }
            return d.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt16.self).littleEndian }
        }

        // Match by UUID, name, or Nordic manufacturer ID
        let isMatch = id == targetAddress
            || name?.lowercased().contains("plaud") == true
            || mfrID == nordicManufacturerID

        guard isMatch else { return }

        scanTimer?.cancel()
        scanTimeoutTimer?.cancel()
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
        Task { await actor?.handleNotification(Data(data)) }
    }
}

// MARK: - Data Hex String

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
