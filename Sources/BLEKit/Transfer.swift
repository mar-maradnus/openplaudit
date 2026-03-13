/// File download over BLE — voice packet capture approach.
///
/// Ported from Python CLI `src/plaude/ble/transfer.py`.

import Foundation

/// Raised when a file download fails.
public struct DownloadError: Error, LocalizedError {
    public let message: String
    public var errorDescription: String? { message }

    public init(_ message: String) {
        self.message = message
    }
}

/// Download a recording from the device.
///
/// The device sends file data as proto_type=0x02 (voice) packets after
/// SYNC_FILE_START, then sends SYNC_FILE_TAIL with CRC when done.
///
/// Returns raw Opus bytes (with 9-byte per-frame headers).
public func downloadFile(
    client: PlaudClient,
    sessionID: UInt32,
    fileSize: UInt32,
    verbose: Bool = false,
    progress: ((Int, Int, Double) -> Void)? = nil
) async throws -> Data {
    await client.resetVoiceBuffer()
    await client.setReceiving(true)

    // file_size from device = raw frame bytes; actual BLE data includes 9-byte headers
    // per 80-byte frame, so expected_size ≈ file_size * 89/80
    let expectedSize = Int(Double(fileSize) * 89.0 / 80.0)

    defer { Task { await client.setReceiving(false) } }

    // SYNC_FILE_START (cmd 28): session_id, offset=0, file_size
    var payload = Data(capacity: 12)
    var sid = sessionID.littleEndian
    var offset: UInt32 = 0
    var fs = fileSize.littleEndian
    payload.append(Data(bytes: &sid, count: 4))
    payload.append(Data(bytes: &offset, count: 4))
    payload.append(Data(bytes: &fs, count: 4))

    try await client.send(cmdSyncFileStart, payload: payload)

    guard let head = await client.waitResponse(cmdSyncFileStart, timeout: 10.0) else {
        throw DownloadError("No file head response from device")
    }

    if head.count >= 5 && head[4] != 0 {
        throw DownloadError("Transfer rejected by device (status=\(head[4]))")
    }

    // Collect voice packets until SYNC_FILE_TAIL
    let start = Date()
    var lastSize = 0
    var stallCount = 0

    while true {
        if let tail = await client.waitResponse(cmdSyncFileTail, timeout: 0.5) {
            // Got tail — validate and return
            let fileData = await client.voiceData

            if fileData.isEmpty {
                throw DownloadError("Transfer completed but no data received")
            }

            // Size sanity: allow 10% under-delivery
            let minAcceptable = Int(Double(expectedSize) * 0.90)
            if fileData.count < minAcceptable {
                throw DownloadError(
                    "Transfer too short: got \(fileData.count) bytes, expected >= \(minAcceptable) (~\(expectedSize))"
                )
            }

            // Structural invariant: BLE voice packets are 89 bytes each
            if fileData.count % 89 != 0 {
                throw DownloadError(
                    "Data not 89-byte aligned: \(fileData.count) bytes (remainder=\(fileData.count % 89))"
                )
            }

            // Tail packet validation
            guard tail.count >= 6 else {
                throw DownloadError("Malformed tail packet: expected >=6 bytes, got \(tail.count)")
            }

            let deviceCRC = tail.withUnsafeBytes { ptr -> UInt16 in
                ptr.loadUnaligned(fromByteOffset: 4, as: UInt16.self).littleEndian
            }
            let localCRC = crc16CCITT(fileData)
            let crcSkipped = deviceCRC == 0xFFFF

            if verbose {
                if crcSkipped {
                    print("  CRC: skipped by device (0xFFFF)")
                } else {
                    let match = deviceCRC == localCRC ? "OK" : "MISMATCH"
                    print("  CRC: 0x\(String(format: "%04x", deviceCRC))/0x\(String(format: "%04x", localCRC)) \(match)")
                }
            }

            // Send checksum acknowledgement
            var ackPayload = Data(capacity: 3)
            ackPayload.append(0)
            var crcLE = localCRC.littleEndian
            ackPayload.append(Data(bytes: &crcLE, count: 2))
            try await client.send(cmdFileChecksum, payload: ackPayload)
            _ = await client.waitResponse(cmdFileChecksumRsp, timeout: 5.0)

            if !crcSkipped && deviceCRC != localCRC {
                throw DownloadError(
                    "CRC mismatch: device=0x\(String(format: "%04x", deviceCRC)) local=0x\(String(format: "%04x", localCRC))"
                )
            }

            return fileData
        }

        // Check for progress / stall
        let current = await client.voiceData.count
        if current != lastSize {
            stallCount = 0
            lastSize = current
            let elapsed = Date().timeIntervalSince(start)
            let pct = min(Double(current) / Double(expectedSize) * 100.0, 100.0)
            progress?(current, expectedSize, pct)

            if verbose {
                let speed = elapsed > 0 ? Double(current) / elapsed : 0
                let pkts = await client.voicePacketCount
                print("\r  \(current)/\(expectedSize) (\(String(format: "%.1f", pct))%) \(String(format: "%.1f", speed / 1024)) KB/s [\(pkts) pkts]", terminator: "")
                fflush(stdout)
            }
        } else {
            stallCount += 1
            if stallCount > 20 {  // 10s with no data
                throw DownloadError(
                    "Transfer stalled at \(current)/\(expectedSize) bytes after \(String(format: "%.0f", Date().timeIntervalSince(start)))s"
                )
            }
        }
    }
}

