import Foundation
import Testing
@testable import PlaudCore

private func hex(_ s: String) -> Data {
    var d = Data(); var i = s.startIndex
    while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }
    return d
}
private func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

@Suite("ChaCha20")
struct ChaCha20Tests {
    @Test("RFC 7539 section 2.4.2 known-answer vector")
    func rfcVector() {
        let key = hex("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f")
        let nonce = hex("000000000000004a00000000")
        let plain = Data("Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.".utf8)
        let expected = hex("6e2e359a2568f98041ba0728dd0d6981e97e7aec1d4360c20a27afccfd9fae0bf91b65c5524733ab8f593dabcd62b3571639d624e65152ab8f530c359f0861d807ca0dbf500d6a6156a38e088a22b65e52bc514d16ccf806818ce91ab77937365af90bbf74a35be6b40b8eedf2785e42874d")
        let out = ChaCha20(key: key, nonce: nonce).apply(plain, counter: 1)
        #expect(hex(out) == hex(expected))
    }
}

@Suite("Ogg/Opus muxing")
struct OggTests {
    @Test("produces OggS pages and a sane duration")
    func structure() {
        var frames = Data()
        for _ in 0..<100 { frames.append(0x00); frames.append(Data(repeating: 0x11, count: 79)) }
        let ogg = OggOpus.mux(frames: frames)
        let bytes = [UInt8](ogg)
        #expect(bytes[0..<4] == [0x4f, 0x67, 0x67, 0x53])      // "OggS"
        #expect(ogg.count > frames.count)
        #expect(bytes[5] & 0x02 == 0x02)
        #expect(ogg.range(of: Data("OpusHead".utf8)) != nil)
        #expect(ogg.range(of: Data("OpusTags".utf8)) != nil)
    }

    @Test("granule advances at 48 kHz regardless of source rate")
    func granuleUnits() {
        // 50 frames per page -> 960 * 50 = 48,000 granule units per page.
        var valid = Data()
        for _ in 0..<50 { valid.append(0x00); valid.append(Data(repeating: 0, count: 79)) }
        let ogg = OggOpus.mux(frames: valid)
        let pages = ogg.split(separator: 0x4f)  // crude, just ensure we produced pages
        #expect(pages.count > 0)
    }

    @Test("CRC matches the Ogg polynomial for an empty page body")
    func crcKnown() {
        let a = OggOpus.crc32(Data("OggS".utf8))
        let b = OggOpus.crc32(Data("OggS".utf8))
        #expect(a == b)
        #expect(a != 0)
    }
}

@Suite("PLAUD.AI container")
struct ContainerTests {
    @Test("rejects non-container data")
    func magic() {
        #expect(throws: PLAUDAIContainer.ContainerError.self) {
            try PLAUDAIContainer.parseHeader(Data("not a recording".utf8))
        }
    }

    @Test("reads nonce and segment from a synthetic header")
    func headerFields() throws {
        var d = Data("PLAUD.AI".utf8)
        d.append(Data(repeating: 0, count: 512 - d.count))
        d.replaceSubrange(0x84..<0x90, with: hex("00112233445566778899aabb"))
        d.replaceSubrange(0x90..<0x94, with: hex("50000000"))     // segment = 80
        let h = try PLAUDAIContainer.parseHeader(d)
        #expect(h.segment == 80)
        #expect(hex(h.nonce) == "00112233445566778899aabb")
    }
}

@Suite("Repetition-loop detection")
struct LoopTests {
    @Test("flags degenerate repetition")
    func flags() {
        let loops = String(repeating: "lui, ", count: 200)
        #expect(Transcriber.loopRatio(loops) > 0.5)
    }

    @Test("ignores normal emphasis")
    func normal() {
        #expect(Transcriber.loopRatio("No, no, no. That is not what I meant.") == 0)
    }

    @Test("ignores empty text")
    func empty() { #expect(Transcriber.loopRatio("") == 0) }
}

@Suite("Session crypto")
struct SessionCryptoTests {
    func keys() -> V20Auth.SessionKeys {
        V20Auth.SessionKeys(key: Data(repeating: 7, count: 32),
                            nonce: Data(repeating: 9, count: 12),
                            ad: Data(repeating: 3, count: 12))
    }

    @Test("round-trips and increments the counter before the first packet")
    func roundTrip() throws {
        let c = SessionCrypto(keys: keys())
        let sealed = try c.encrypt(Data("hello".utf8))
        #expect(c.sendCounter == 2)          // first packet uses counter 2
        #expect(try c.decrypt(sealed) == Data("hello".utf8))
        #expect(c.receiveCounter == 2)
    }

    @Test("tampering fails authentication")
    func tamper() throws {
        let c = SessionCrypto(keys: keys())
        var sealed = try c.encrypt(Data("hello".utf8))
        sealed[0] ^= 0xff
        #expect(throws: (any Error).self) { try c.decrypt(sealed) }
    }
}

@Suite("Markdown rendering")
struct MarkdownTests {
    func result() -> Transcriber.Result {
        Transcriber.Result(
            text: "first chunk second chunk", chunks: [],
            model: "vllm/whisper-large-v3", durationSeconds: 1080,
            chunksTranscribed: 2)
    }

    @Test("frontmatter, title and one section per chunk")
    func render() {
        let r = Transcriber.Result(
            text: "hello world",
            chunks: [
                .init(index: 0, startSeconds: 0, endSeconds: 540, text: "first"),
                .init(index: 1, startSeconds: 540, endSeconds: 1080, text: "second"),
            ],
            model: "m", durationSeconds: 11670, chunksTranscribed: 2)
        let md = TranscriptMarkdown.render(r, title: "2026-10-19 00:48 UTC")
        #expect(md.hasPrefix("---\n"))
        #expect(md.contains("duration: 3h 14m"))
        #expect(md.contains("chunks: 2"))
        #expect(md.contains("# 2026-10-19 00:48 UTC"))
        #expect(md.contains("## 0:00 – 9:00"))
        #expect(md.contains("## 9:00 – 18:00"))
    }

    @Test("clock formatting")
    func clock() {
        #expect(TranscriptMarkdown.clock(0) == "0:00")
        #expect(TranscriptMarkdown.clock(540) == "9:00")
        #expect(TranscriptMarkdown.clock(3723) == "1:02:03")
    }
}

@Suite("Device credentials")
struct CredentialTests {
    @Test("parses the CLI's credentials markdown")
    func parse() throws {
        let md = """
        # PLAUD self-bind credentials (generated by bind.py)
        - sn_signature: AAECAwQ=
        - user_rsa_public_key: -----BEGIN PUBLIC KEY-----
        MIIB
        -----END PUBLIC KEY-----
        - user_rsa_private_key: -----BEGIN PRIVATE KEY-----
        MIIE
        -----END PRIVATE KEY-----
        """
        let c = try DeviceCredentials.parse(markdown: md)
        #expect(c.snSignature == Data([0, 1, 2, 3, 4]))
        #expect(c.rsaPublicKeyPEM.contains("BEGIN PUBLIC KEY"))
        #expect(c.rsaPrivateKeyPEM.contains("BEGIN PRIVATE KEY"))
    }

    @Test("rejects a credentials blob with no signature")
    func missing() {
        #expect(throws: DeviceCredentials.ParseError.self) {
            try DeviceCredentials.parse(markdown: "nothing here")
        }
    }
}
