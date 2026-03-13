/// BLE protocol primitives — packet building, CRC, command constants.
///
/// Ported from Python CLI `src/plaude/ble/protocol.py`.

import Foundation

// MARK: - PLAUD BLE UUIDs

public let serviceUUID = "00001910-0000-1000-8000-00805F9B34FB"
public let txUUID      = "00002BB0-0000-1000-8000-00805F9B34FB"  // device → host (notify)
public let rxUUID      = "00002BB1-0000-1000-8000-00805F9B34FB"  // host → device (write)

// MARK: - Protocol Types

public let protoCommand: UInt8 = 0x01
public let protoVoice: UInt8   = 0x02

// MARK: - Command IDs

public let cmdHandshake: UInt16       = 1
public let cmdGetState: UInt16        = 3
public let cmdTimeSync: UInt16        = 4
public let cmdGetStorage: UInt16      = 6
public let cmdGetRecSessions: UInt16  = 26
public let cmdSyncFileStart: UInt16   = 28
public let cmdSyncFileTail: UInt16    = 29
public let cmdFileInfoSync: UInt16    = 112
public let cmdFileInfoSyncRsp: UInt16 = 113
public let cmdFileSyncData: UInt16    = 114
public let cmdFileChecksum: UInt16    = 116
public let cmdFileChecksumRsp: UInt16 = 117

public let cmdNames: [UInt16: String] = [
    1: "HANDSHAKE", 3: "GET_STATE", 4: "TIME_SYNC", 6: "GET_STORAGE",
    26: "GET_REC_SESSIONS", 28: "SYNC_FILE_HEAD", 29: "SYNC_FILE_TAIL",
    112: "FILE_INFO_SYNC", 113: "FILE_INFO_SYNC_RSP",
    114: "FILE_SYNC_DATA", 116: "FILE_CHECKSUM", 117: "FILE_CHECKSUM_RSP",
]

// MARK: - Packet Building

/// Build a BLE command packet: [proto_type:1][cmd_id:2LE][payload].
public func buildCmd(_ cmdID: UInt16, payload: Data = Data()) -> Data {
    var data = Data(capacity: 3 + payload.count)
    data.append(protoCommand)
    var le = cmdID.littleEndian
    data.append(Data(bytes: &le, count: 2))
    data.append(payload)
    return data
}

// MARK: - CRC-16/CCITT-FALSE

/// CRC-16/CCITT-FALSE used by PLAUD for file transfer verification.
/// Polynomial: 0x1021, initial value: 0xFFFF.
public func crc16CCITT(_ data: Data) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            if crc & 0x8000 != 0 {
                crc = (crc << 1) ^ 0x1021
            } else {
                crc <<= 1
            }
            crc &= 0xFFFF
        }
    }
    return crc
}

// MARK: - Session Parsing

/// A recording session reported by the device.
public struct RecordingSession: Equatable, Sendable {
    public let sessionID: UInt32
    public let fileSize: UInt32
    public let scene: UInt16

    public init(sessionID: UInt32, fileSize: UInt32, scene: UInt16) {
        self.sessionID = sessionID
        self.fileSize = fileSize
        self.scene = scene
    }
}

/// Parse GET_REC_SESSIONS response into a list of sessions.
///
/// Payload format:
///   [4 bytes unknown][count:4LE]
///   Then `count` entries of: [session_id:4LE][file_size:4LE][scene:2LE]
public func parseSessions(_ payload: Data) -> [RecordingSession] {
    guard payload.count >= 8 else { return [] }

    let count = payload.loadLittleEndianUInt32(at: 4)
    var sessions: [RecordingSession] = []
    var offset = 8

    for _ in 0..<count {
        guard offset + 10 <= payload.count else { break }
        let sessionID = payload.loadLittleEndianUInt32(at: offset)
        let fileSize = payload.loadLittleEndianUInt32(at: offset + 4)
        let scene = payload.loadLittleEndianUInt16(at: offset + 8)
        sessions.append(RecordingSession(sessionID: sessionID, fileSize: fileSize, scene: scene))
        offset += 10
    }

    return sessions
}

// MARK: - Data Helpers

extension Data {
    func loadLittleEndianUInt16(at offset: Int) -> UInt16 {
        self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt16.self).littleEndian
        }
    }

    func loadLittleEndianUInt32(at offset: Int) -> UInt32 {
        self.withUnsafeBytes { ptr in
            ptr.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
        }
    }
}
