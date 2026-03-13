/// Tests for Opus frame extraction from raw BLE packets.
/// Ported from Python CLI `tests/test_decoder.py`.

import Foundation
import Testing
@testable import AudioKit

private func makePacket(sessionID: UInt32, offset: UInt32, frameSize: UInt8, frameData: Data = Data()) -> Data {
    var pkt = Data(capacity: packetSize)
    var sid = sessionID.littleEndian
    var off = offset.littleEndian
    pkt.append(Data(bytes: &sid, count: 4))
    pkt.append(Data(bytes: &off, count: 4))
    pkt.append(frameSize)
    let data = frameData.prefix(Int(frameSize))
    pkt.append(data)
    if pkt.count < packetSize {
        pkt.append(Data(count: packetSize - pkt.count))
    }
    return pkt
}

@Suite("extractOpusFrames")
struct ExtractOpusFramesTests {
    @Test func emptyData() {
        #expect(extractOpusFrames(Data()).isEmpty)
    }

    @Test func singlePacket() {
        let frame = Data(0..<80)
        let pkt = makePacket(sessionID: 1000, offset: 0, frameSize: 80, frameData: frame)
        #expect(pkt.count == packetSize)
        let frames = extractOpusFrames(pkt)
        #expect(frames.count == 1)
        #expect(frames[0] == frame)
    }

    @Test func multiplePackets() {
        var raw = Data()
        for i: UInt8 in 0..<5 {
            raw.append(makePacket(sessionID: 1000, offset: UInt32(i) * 80, frameSize: 80,
                                  frameData: Data(repeating: i, count: 80)))
        }
        let frames = extractOpusFrames(raw)
        #expect(frames.count == 5)
        #expect(frames[3] == Data(repeating: 3, count: 80))
    }

    @Test func variableFrameSizes() {
        var raw = makePacket(sessionID: 1000, offset: 0, frameSize: 60,
                             frameData: Data(repeating: 0xAA, count: 60))
        raw.append(makePacket(sessionID: 1000, offset: 60, frameSize: 40,
                              frameData: Data(repeating: 0xBB, count: 40)))
        let frames = extractOpusFrames(raw)
        #expect(frames.count == 2)
        #expect(frames[0].count == 60)
        #expect(frames[1].count == 40)
    }

    @Test func zeroFrameSkipped() {
        var raw = makePacket(sessionID: 1000, offset: 0, frameSize: 0)
        raw.append(makePacket(sessionID: 1000, offset: 80, frameSize: 80,
                              frameData: Data(repeating: 0xFF, count: 80)))
        let frames = extractOpusFrames(raw)
        #expect(frames.count == 1)
    }

    @Test func oversizeFrameSkipped() {
        var pkt = Data(capacity: packetSize)
        var sid: UInt32 = 1000
        var off: UInt32 = 0
        pkt.append(Data(bytes: &sid, count: 4))
        pkt.append(Data(bytes: &off, count: 4))
        pkt.append(81)
        pkt.append(Data(count: packetSize - pkt.count))
        let frames = extractOpusFrames(pkt)
        #expect(frames.isEmpty)
    }

    @Test func realFilePacketCount() {
        let fileSize = 96720
        let raw = Data(count: fileSize)
        let frames = extractOpusFrames(raw)
        _ = frames  // Just verify no crash
    }
}
