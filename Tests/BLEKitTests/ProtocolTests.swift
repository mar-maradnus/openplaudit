/// Tests for BLE protocol primitives — packet building, CRC, session parsing.
/// Ported from Python CLI `tests/test_protocol.py`.

import Foundation
import Testing
@testable import BLEKit

@Suite("buildCmd")
struct BuildCmdTests {
    @Test func buildsCorrectHeader() {
        let pkt = buildCmd(1)
        #expect(pkt[0] == protoCommand)
        let cmdID = pkt.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt16.self).littleEndian
        }
        #expect(cmdID == 1)
        #expect(pkt.count == 3)
    }

    @Test func appendsPayload() {
        let payload = Data([0xAA, 0xBB, 0xCC])
        let pkt = buildCmd(26, payload: payload)
        #expect(pkt[0] == protoCommand)
        let cmdID = pkt.withUnsafeBytes { ptr -> UInt16 in
            ptr.loadUnaligned(fromByteOffset: 1, as: UInt16.self).littleEndian
        }
        #expect(cmdID == 26)
        #expect(Data(pkt.dropFirst(3)) == payload)
    }

    @Test func handshakePacketStructure() {
        let token = "00112233445566778899aabbccddeeff"
        var tokenBytes = Data(token.utf8.prefix(32))
        while tokenBytes.count < 32 { tokenBytes.append(0) }
        let payload = Data([0x02, 0x00, 0x00]) + tokenBytes
        let pkt = buildCmd(1, payload: payload)
        #expect(pkt.count == 3 + 3 + 32)
    }
}

@Suite("crc16CCITT")
struct CRC16Tests {
    @Test func emptyData() {
        #expect(crc16CCITT(Data()) == 0xFFFF)
    }

    @Test func knownValue() {
        #expect(crc16CCITT(Data("123456789".utf8)) == 0x29B1)
    }

    @Test func deterministic() {
        let data = Data(repeating: 0, count: 400)
        #expect(crc16CCITT(data) == crc16CCITT(data))
    }

    @Test func differentData() {
        #expect(crc16CCITT(Data([0x00])) != crc16CCITT(Data([0x01])))
    }
}

@Suite("parseSessions")
struct ParseSessionsTests {
    @Test func emptyPayload() {
        #expect(parseSessions(Data()).isEmpty)
        #expect(parseSessions(Data(count: 4)).isEmpty)
    }

    @Test func zeroCount() {
        var payload = Data(count: 4)
        var count: UInt32 = 0
        payload.append(Data(bytes: &count, count: 4))
        #expect(parseSessions(payload).isEmpty)
    }

    @Test func singleSession() {
        let sessionID: UInt32 = 1741747438
        let fileSize: UInt32 = 96720
        let scene: UInt16 = 1

        var payload = Data(count: 4)
        var count: UInt32 = 1
        payload.append(Data(bytes: &count, count: 4))

        var sid = sessionID.littleEndian
        var fs = fileSize.littleEndian
        var sc = scene.littleEndian
        payload.append(Data(bytes: &sid, count: 4))
        payload.append(Data(bytes: &fs, count: 4))
        payload.append(Data(bytes: &sc, count: 2))

        let sessions = parseSessions(payload)
        #expect(sessions.count == 1)
        #expect(sessions[0].sessionID == sessionID)
        #expect(sessions[0].fileSize == fileSize)
        #expect(sessions[0].scene == scene)
    }

    @Test func multipleSessions() {
        var payload = Data(count: 4)
        var count: UInt32 = 3
        payload.append(Data(bytes: &count, count: 4))

        for i in 0..<3 {
            var sid = UInt32(1000 + i).littleEndian
            var fs = UInt32(5000 * (i + 1)).littleEndian
            var sc = UInt16(i).littleEndian
            payload.append(Data(bytes: &sid, count: 4))
            payload.append(Data(bytes: &fs, count: 4))
            payload.append(Data(bytes: &sc, count: 2))
        }

        let sessions = parseSessions(payload)
        #expect(sessions.count == 3)
        #expect(sessions[2].sessionID == 1002)
        #expect(sessions[2].fileSize == 15000)
    }

    @Test func truncatedPayload() {
        var payload = Data(count: 4)
        var count: UInt32 = 2
        payload.append(Data(bytes: &count, count: 4))

        var sid: UInt32 = 1000
        var fs: UInt32 = 5000
        var sc: UInt16 = 0
        payload.append(Data(bytes: &sid, count: 4))
        payload.append(Data(bytes: &fs, count: 4))
        payload.append(Data(bytes: &sc, count: 2))

        payload.append(Data(count: 5))

        let sessions = parseSessions(payload)
        #expect(sessions.count == 1)
    }
}
