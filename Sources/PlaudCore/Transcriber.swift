import Foundation

public struct Transcriber {
    public struct Chunk: Sendable {
        public let index: Int
        public let startSeconds: Double
        public let endSeconds: Double
        public let text: String
    }

    public struct Result: Sendable {
        public let text: String
        public let chunks: [Chunk]
        public let model: String
        public let durationSeconds: Double
        public let chunksTranscribed: Int
    }

    public static let retryLadder: [Double] = [0.2, 0.4, 0.6, 0.8]
    public static let loopRepetitionPenalty = 1.1
    public static let defaultChunkSeconds: Double = 540
    public static let frameSeconds: Double = 0.02

    private static let loopRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "((?:\\b[\\w']+\\b[ ,.]*){1,4}?)(?:\\1){12,}",
        options: [.caseInsensitive])

    public let endpoint: URL
    public let apiKey: String
    public let model: String
    public let chunkSeconds: Double
    private let session: URLSession

    public init(endpoint: URL, apiKey: String, model: String,
                chunkSeconds: Double = Transcriber.defaultChunkSeconds,
                session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.chunkSeconds = chunkSeconds
        self.session = session
    }

    public static func loopChars(_ text: String) -> Int {
        guard let regex = loopRegex else { return 0 }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .reduce(0) { $0 + $1.range.length }
    }

    public static func loopRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0 }
        return Double(loopChars(text)) / Double(text.utf16.count)
    }

    public func transcribe(frames: Data, frameSize: Int = 80,
                           progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> Result {
        let framesPerChunk = max(1, Int(chunkSeconds / Transcriber.frameSeconds))
        let bytesPerChunk = framesPerChunk * frameSize
        let totalFrames = frames.count / frameSize
        var chunks: [Chunk] = []
        var texts: [String] = []
        var offset = 0
        var index = 0

        while offset < frames.count {
            let end = min(offset + bytesPerChunk, frames.count)
            let slice = frames.subdata(in: offset..<end)
            let ogg = OggOpus.mux(frames: slice, frameSize: frameSize)
            let text = try await uploadWithRetry(ogg)
            let start = Double(offset / frameSize) * Transcriber.frameSeconds
            let nFrames = slice.count / frameSize
            let finish = start + Double(nFrames) * Transcriber.frameSeconds
            chunks.append(Chunk(index: index, startSeconds: start,
                                endSeconds: finish, text: text))
            if !text.isEmpty { texts.append(text) }
            progress?(index + 1, (frames.count + bytesPerChunk - 1) / bytesPerChunk)
            index += 1
            offset = end
        }

        let duration = Double(totalFrames) * Transcriber.frameSeconds
        return Result(text: texts.joined(separator: " "), chunks: chunks,
                      model: model, durationSeconds: duration,
                      chunksTranscribed: chunks.count)
    }

    public func uploadWithRetry(_ audio: Data) async throws -> String {
        let first = try await upload(audio, extra: [])
        guard Transcriber.loopRatio(first) > 0 else { return first }

        var best = first
        var bestRatio = Transcriber.loopRatio(first)
        for temp in Transcriber.retryLadder {
            let candidate = try await upload(audio, extra: [
                ("temperature", String(temp)),
                ("repetition_penalty", String(Transcriber.loopRepetitionPenalty)),
            ])
            let ratio = Transcriber.loopRatio(candidate)
            if ratio < bestRatio { best = candidate; bestRatio = ratio }
            if ratio == 0 { return candidate }
        }
        return best
    }

    public func upload(_ audio: Data, extra: [(String, String)]) async throws -> String {
        let boundary = "----plaude"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model)
        for (k, v) in extra { field(k, v) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.ogg\"\r\nContent-Type: audio/ogg\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        req.timeoutInterval = 600

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriberError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw TranscriberError.http(http.statusCode, String(msg.prefix(300)))
        }
        struct Payload: Decodable { let text: String? }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        return (payload.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum TranscriberError: Error, LocalizedError {
    case badResponse
    case http(Int, String)

    public var errorDescription: String? {
        switch self {
        case .badResponse: return "Transcription: unexpected response"
        case .http(let code, let body):
            return "Transcription failed (HTTP \(code)): \(body)"
        }
    }
}
