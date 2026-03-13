/// BLE device scanning — CoreBluetooth scan with Nordic fallback.
///
/// Ported from Python CLI `src/plaude/ble/client.py` (scan method).

import CoreBluetooth
import Foundation

/// A discovered BLE device.
public struct DiscoveredDevice: Sendable {
    public let name: String
    public let identifier: UUID
    public let rssi: Int

    public init(name: String, identifier: UUID, rssi: Int) {
        self.name = name
        self.identifier = identifier
        self.rssi = rssi
    }
}

/// Scans for PLAUD BLE devices using CoreBluetooth.
public actor BLEScanner {
    private let delegate: ScannerDelegate
    private var centralManager: CBCentralManager?

    public init() {
        self.delegate = ScannerDelegate()
    }

    /// Scan for PLAUD devices. Returns discovered devices after timeout.
    public func scan(timeout: TimeInterval = 15.0) async -> [DiscoveredDevice] {
        await withCheckedContinuation { continuation in
            delegate.onComplete = { devices in
                continuation.resume(returning: devices)
            }
            delegate.timeout = timeout

            let cm = CBCentralManager(delegate: delegate, queue: delegate.queue)
            self.centralManager = cm
        }
    }
}

// MARK: - Delegate Bridge

private final class ScannerDelegate: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.openplaudit.scanner")
    var onComplete: (([DiscoveredDevice]) -> Void)?
    var timeout: TimeInterval = 15.0

    private var found: [UUID: DiscoveredDevice] = [:]
    private var scanTimer: DispatchWorkItem?
    private let plaudServiceUUID = CBUUID(string: serviceUUID)
    private let nordicManufacturerID: UInt16 = 0x0059

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }

        // First try: scan for PLAUD service UUID specifically
        central.scanForPeripherals(
            withServices: [plaudServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        // Schedule fallback broader scan and completion
        let timer = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.found.isEmpty {
                // Fallback: broader scan for Nordic chipset or PLAUD name
                central.stopScan()
                central.scanForPeripherals(
                    withServices: nil,
                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
                )
                let fallbackTimer = DispatchWorkItem { [weak self] in
                    central.stopScan()
                    self?.finish()
                }
                self.queue.asyncAfter(deadline: .now() + self.timeout / 2, execute: fallbackTimer)
                self.scanTimer = fallbackTimer
            } else {
                central.stopScan()
                self.finish()
            }
        }
        scanTimer = timer
        queue.asyncAfter(deadline: .now() + timeout / 2, execute: timer)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                         advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name
                   ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String
                   ?? "(unnamed)"

        // Check if this is a PLAUD device (service UUID match or name/manufacturer)
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let mfrData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data

        let isPlaud = serviceUUIDs.contains(plaudServiceUUID)
                      || name.lowercased().contains("plaud")
                      || (mfrData != nil && loadMfrID(mfrData!) == nordicManufacturerID)

        guard isPlaud else { return }

        found[peripheral.identifier] = DiscoveredDevice(
            name: name,
            identifier: peripheral.identifier,
            rssi: RSSI.intValue
        )
    }

    private func finish() {
        let devices = Array(found.values)
        onComplete?(devices)
        onComplete = nil
    }
}

// MARK: - Data helper for manufacturer ID

private func loadMfrID(_ data: Data) -> UInt16 {
    guard data.count >= 2 else { return 0 }
    return data.withUnsafeBytes { ptr in
        ptr.loadUnaligned(fromByteOffset: 0, as: UInt16.self).littleEndian
    }
}
