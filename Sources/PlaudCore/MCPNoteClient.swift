import Foundation

public struct MCPNoteClient: Sendable {
    public enum MCPError: Error, LocalizedError {
        case noSession
        case http(Int, String)
        case rpc(String)

        public var errorDescription: String? {
            switch self {
            case .noSession: return "Gateway did not return a session id"
            case .http(let c, let b): return "Gateway HTTP \(c): \(b.prefix(200))"
            case .rpc(let m): return "Gateway error: \(m)"
            }
        }
    }

    public let endpoint: URL
    public let token: String
    public let agentID: String?
    public let invokeTool: String
    public let backendServer: String
    public let backendTool: String
    private let session: URLSession

    public init(endpoint: URL, token: String,
                agentID: String? = nil,
                session: URLSession = .shared,
                invokeTool: String = "gateway_invoke",
                backendServer: String? = nil,
                backendTool: String = "write_note") {
        self.endpoint = endpoint
        self.token = token
        self.agentID = agentID
        self.session = session
        self.invokeTool = invokeTool
        self.backendServer = backendServer ?? ""
        self.backendTool = backendTool
    }

    public func writeNote(path: String, content: String) async throws {
        let sid = try await initialize()

        let arguments: [String: Any]
        if backendServer.isEmpty {
            arguments = ["path": path, "content": content]
        } else {
            arguments = [
                "server": backendServer,
                "tool": backendTool,
                "arguments": ["path": path, "content": content],
            ]
        }
        let result = try await rpc([
            "jsonrpc": "2.0", "id": 3, "method": "tools/call",
            "params": ["name": invokeTool, "arguments": arguments],
        ], sessionID: sid)

        if let err = result["error"] {
            throw MCPError.rpc(String(describing: err))
        }
        if let res = result["result"] as? [String: Any],
           let isError = res["isError"] as? Bool, isError {
            throw MCPError.rpc(String(describing: res))
        }
    }

    private func initialize() async throws -> String {
        let (body, headers) = try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:] as [String: Any],
                "clientInfo": ["name": "plaude", "version": "1"],
            ],
        ], sessionID: nil)
        guard let sid = headers["mcp-session-id"] as? String else {
            throw MCPError.noSession
        }
        _ = try? await post(["jsonrpc": "2.0", "method": "notifications/initialized"],
                            sessionID: sid)
        _ = body
        return sid
    }

    private func rpc(_ payload: [String: Any], sessionID: String) async throws -> [String: Any] {
        let (data, _) = try await perform(payload, sessionID: sessionID)
        return try decode(data)
    }

    private func post(_ payload: [String: Any], sessionID: String?) async throws
        -> (Data, [AnyHashable: Any]) {
        try await perform(payload, sessionID: sessionID)
    }

    private func perform(_ payload: [String: Any], sessionID: String?) async throws
        -> (Data, [AnyHashable: Any]) {
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let agentID, !agentID.isEmpty { req.setValue(agentID, forHTTPHeaderField: "X-Agent-ID") }
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let sessionID { req.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        req.timeoutInterval = 120

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.http(-1, "no response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return (data, http.allHeaderFields)
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        let text = String(data: data, encoding: .utf8) ?? ""
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        for line in text.split(separator: "\n") where line.hasPrefix("data: ") {
            let json = String(line.dropFirst(6))
            if let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
                return obj
            }
        }
        throw MCPError.http(200, "unparseable response: \(text.prefix(200))")
    }
}
