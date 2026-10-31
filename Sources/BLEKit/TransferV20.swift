import Foundation
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "transfer")

public struct V20Assembler: Sendable {
    public private(set) var bytes: [UInt8] = []
    public private(set) var expected: Int = 0
    public private(set) var done = false
    public private(set) var gapAt: Int?
    public private(set) var lastProgress = Date()
    public let sessionID: UInt32
    public let fileSize: Int

    public init(sessionID: UInt32, fileSize: Int) {
        self.sessionID = sessionID
        self.fileSize = fileSize
        bytes.reserveCapacity(fileSize)
    }

    public mutating func consume(_ frame: Data) {
        guard frame.count >= 10, frame[0] == 0x02 else { return }
        let sid = UInt32(frame[1]) | (UInt32(frame[2]) << 8)
                 | (UInt32(frame[3]) << 16) | (UInt32(frame[4]) << 24)
        guard sid == sessionID else { return }        // stale frame, earlier file
        let offset = UInt32(frame[5]) | (UInt32(frame[6]) << 8)
                   | (UInt32(frame[7]) << 16) | (UInt32(frame[8]) << 24)
        if offset == 0xFFFF_FFFF { done = true; return }

        let len = Int(frame[9])
        guard frame.count >= 10 + len else { return }
        let slice = frame.subdata(in: 10..<(10 + len))

        if Int(offset) != expected {
            if Int(offset) > expected { gapAt = expected }
            return
        }
        bytes.append(contentsOf: slice)
        expected += len
        lastProgress = Date()
    }

    public mutating func clearGap() { gapAt = nil }

    public var isComplete: Bool { expected >= fileSize || done }
}

extension PlaudClient {
    public func deviceState() async -> Data? {
        do {
            try await send(cmdGetState)
            guard let r = await waitResponse(cmdGetState, timeout: 5.0), r.count > 3 else {
                return nil
            }
            return r.subdata(in: 3..<r.count)
        } catch { return nil }
    }

    // There is no BLE delete command; STOP is the only release mechanism.
    public func releaseSession(_ sessionID: UInt32) async {
        var payload = Data()
        var sid = sessionID.littleEndian
        payload.append(Data(bytes: &sid, count: 4))
        try? await send(cmdSyncFileStop, payload: payload)
    }

    public func batteryStatus() async -> (level: Int, charging: Bool)? {
        do {
            try await send(cmdBattStatus)
            guard let resp = await waitResponse(cmdBattStatus, timeout: 6.0),
                  resp.count >= 2, resp[1] <= 100 else { return nil }
            return (level: Int(resp[1]), charging: resp[0] != 0)
        } catch {
            return nil
        }
    }

    public func batteryLevel() async -> Int? {
        await batteryStatus()?.level
    }

    public func downloadFileV20(
        sessionID: UInt32,
        fileSize: UInt32,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> Data {
        let assembler = V20Assembler(sessionID: sessionID, fileSize: Int(fileSize))
        self.beginAssembly(assembler)

        defer { self.endAssembly() }

        var resends = 0
        let maxResendsAtOffset = 20

        func startFrom(_ offset: UInt32) async throws {
            var payload = Data()
            var sid = sessionID.littleEndian
            var off = offset.littleEndian
            var fs = fileSize.littleEndian
            payload.append(Data(bytes: &sid, count: 4))
            payload.append(Data(bytes: &off, count: 4))
            payload.append(Data(bytes: &fs, count: 4))
            try await send(cmdSyncFileStart, payload: payload)
            guard let head = await waitResponse(cmdSyncFileStart, timeout: 10.0) else {
                throw DownloadError("No response to SYNC_FILE_HEAD")
            }
            if head.count >= 5, head[4] != 0 {
                throw DownloadError("Device rejected the transfer (status \(head[4]))")
            }
        }

        try await startFrom(0)

        let deadline = Date().addingTimeInterval(3600)
        var lastSeen = -1
        var stalledSince = Date()

        while Date() < deadline {
            guard let state = self.assemblerState() else { break }

            if state.isComplete { break }
            if let gap = state.gapAt {
                resends += 1
                guard resends <= maxResendsAtOffset else {
                    throw DownloadError("Transfer stuck: device would not resend from \(gap)")
                }
                log.info("gap at \(gap) — resending")
                self.clearGap()
                try await startFrom(UInt32(gap))
                continue
            }
            if state.expected != lastSeen {
                lastSeen = state.expected
                stalledSince = Date()
                progress?(state.expected, Int(fileSize))
            } else if Date().timeIntervalSince(stalledSince) > 120 {
                throw DownloadError(
                    "Transfer stalled at \(state.expected)/\(fileSize) bytes")
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        guard let final = self.assemblerState() else {
            throw DownloadError("Transfer state lost")
        }
        guard final.expected >= Int(fileSize) else {
            throw DownloadError(
                "Transfer incomplete: \(final.expected)/\(fileSize) bytes")
        }

        // SYNC_FILE_STOP dropped the device session count from 7 to 6.
        var stop = Data()
        var sid = sessionID.littleEndian
        stop.append(Data(bytes: &sid, count: 4))
        try? await send(cmdSyncFileStop, payload: stop)

        return Data(final.bytes)
    }
}
