/// Sync server — macOS side of the companion sync protocol.
///
/// Advertises via Bonjour (_openplaudit._tcp), accepts TCP connections from
/// an iPhone companion, authenticates via HMAC challenge-response, receives
/// recording uploads, and sends back transcripts.

#if os(macOS)
import Foundation
import Network
import CryptoKit
import SharedKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "sync-server")

/// Delegate for SyncServer events — implemented by the macOS app to trigger
/// pipeline processing and UI updates.
public protocol SyncServerDelegate: AnyObject, Sendable {
    /// Called when a companion device connects and authenticates.
    func syncServerDidConnect(deviceName: String, deviceID: String)
    /// Called when a companion device disconnects.
    func syncServerDidDisconnect()
    /// Called when a recording has been fully received and verified.
    func syncServerDidReceiveRecording(id: String, wavPath: URL)
    /// Called when an error occurs.
    func syncServerDidEncounterError(_ error: Error)
}

/// macOS sync server — listens for companion connections over the local network.
public final class SyncServer: @unchecked Sendable {
    private var listener: NWListener?
    private var activeConnection: NWConnection?
    private let pairingKey: SymmetricKey
    private let queue = DispatchQueue(label: "com.openplaudit.sync-server")
    private let outputDir: URL
    public weak var delegate: SyncServerDelegate?

    // State for receiving chunked uploads
    private var pendingUploads: [String: Data] = [:]
    private var receiveBuffer = Data()

    public init(pairingKey: SymmetricKey, outputDir: URL) {
        self.pairingKey = pairingKey
        self.outputDir = outputDir
    }

    /// Start advertising and listening for companion connections.
    public func start() throws {
        let params = NWParameters.tcp
        params.includePeerToPeer = true

        let listener = try NWListener(using: params)
        listener.service = NWListener.Service(type: syncServiceType)

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port {
                    log.info("Sync server listening on port \(port.rawValue)")
                }
            case .failed(let error):
                log.error("Sync server failed: \(error.localizedDescription)")
                self?.delegate?.syncServerDidEncounterError(error)
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener.start(queue: queue)
        self.listener = listener
    }

    /// Stop the server and close any active connection.
    public func stop() {
        listener?.cancel()
        listener = nil
        activeConnection?.cancel()
        activeConnection = nil
    }

    /// Send a transcript back to the connected companion.
    public func sendTranscript(recordingID: String, transcript: TranscriptionResult) {
        guard let connection = activeConnection else { return }
        let message = SyncMessage.transcriptReady(recordingID: recordingID, transcript: transcript)
        sendMessage(message, on: connection)
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        // Only allow one connection at a time
        if let existing = activeConnection {
            existing.cancel()
        }
        activeConnection = connection
        receiveBuffer = Data()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.info("Companion connected")
                self?.startAuthChallenge(on: connection)
            case .failed(let error):
                log.error("Connection failed: \(error.localizedDescription)")
                self?.activeConnection = nil
                self?.delegate?.syncServerDidDisconnect()
            case .cancelled:
                self?.activeConnection = nil
                self?.delegate?.syncServerDidDisconnect()
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func startAuthChallenge(on connection: NWConnection) {
        let nonce = generateNonce()
        let challenge = SyncMessage.authChallenge(nonce: nonce)
        sendMessage(challenge, on: connection)

        receiveMessage(on: connection) { [weak self] message in
            guard let self else { return }
            switch message {
            case .hello(let name, let deviceID):
                // Client sends hello first, then we challenge
                // Re-send challenge after receiving hello
                self.sendMessage(SyncMessage.authChallenge(nonce: nonce), on: connection)
                self.receiveMessage(on: connection) { authMsg in
                    self.handleAuthResponse(authMsg, nonce: nonce, deviceName: name, deviceID: deviceID, on: connection)
                }
            case .authResponse(let hmac):
                // Direct auth response (deviceID from previous hello)
                self.handleAuthResponse(message, nonce: nonce, deviceName: "Companion", deviceID: "", on: connection)
            default:
                log.warning("Unexpected message during auth: \(String(describing: message))")
                connection.cancel()
            }
        }
    }

    private func handleAuthResponse(_ message: SyncMessage, nonce: Data, deviceName: String, deviceID: String, on connection: NWConnection) {
        guard case .authResponse(let hmac) = message else {
            log.warning("Expected authResponse, got \(String(describing: message))")
            connection.cancel()
            return
        }

        guard verifyHMAC(mac: hmac, data: nonce, key: pairingKey) else {
            log.warning("HMAC verification failed — wrong pairing key")
            sendMessage(.error("Authentication failed"), on: connection)
            connection.cancel()
            return
        }

        log.info("Companion authenticated: \(deviceName)")
        sendMessage(.ack(messageID: "auth"), on: connection)
        delegate?.syncServerDidConnect(deviceName: deviceName, deviceID: deviceID)
        startReceiveLoop(on: connection)
    }

    private func startReceiveLoop(on connection: NWConnection) {
        receiveMessage(on: connection) { [weak self] message in
            guard let self else { return }
            self.handleMessage(message, on: connection)
            self.startReceiveLoop(on: connection)
        }
    }

    private func handleMessage(_ message: SyncMessage, on connection: NWConnection) {
        switch message {
        case .recordingManifest(let manifests):
            // Determine which recordings we need (don't have yet)
            let needed = manifests.filter { meta in
                let path = self.outputDir.appendingPathComponent(meta.filename)
                return !FileManager.default.fileExists(atPath: path.path)
            }
            let neededIDs = needed.map(\.id)
            log.info("Manifest received: \(manifests.count) recordings, \(neededIDs.count) needed")
            sendMessage(.ack(messageID: "need:\(neededIDs.joined(separator: ","))"), on: connection)

        case .uploadChunk(let recordingID, let offset, let data):
            if pendingUploads[recordingID] == nil {
                pendingUploads[recordingID] = Data()
            }
            pendingUploads[recordingID]?.append(data)

        case .uploadComplete(let recordingID, let expectedSHA):
            guard let uploadData = pendingUploads.removeValue(forKey: recordingID) else {
                sendMessage(.error("No pending upload for \(recordingID)"), on: connection)
                return
            }
            let actualSHA = sha256Hex(uploadData)
            guard actualSHA == expectedSHA else {
                log.error("SHA256 mismatch for \(recordingID): expected \(expectedSHA), got \(actualSHA)")
                sendMessage(.error("SHA256 mismatch for \(recordingID)"), on: connection)
                return
            }
            do {
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let wavPath = outputDir.appendingPathComponent("\(recordingID).wav")
                try uploadData.write(to: wavPath, options: .atomic)
                log.info("Recording \(recordingID) saved (\(uploadData.count) bytes)")
                sendMessage(.ack(messageID: recordingID), on: connection)
                delegate?.syncServerDidReceiveRecording(id: recordingID, wavPath: wavPath)
            } catch {
                log.error("Failed to save recording \(recordingID): \(error.localizedDescription)")
                sendMessage(.error("Failed to save: \(error.localizedDescription)"), on: connection)
            }

        case .ack:
            break // Client acknowledged our message

        default:
            log.warning("Unexpected message: \(String(describing: message))")
        }
    }

    // MARK: - Framed Message I/O

    private func sendMessage(_ message: SyncMessage, on connection: NWConnection) {
        do {
            let frame = try encodeFrame(message)
            connection.send(content: frame, completion: .contentProcessed { error in
                if let error {
                    log.error("Send failed: \(error.localizedDescription)")
                }
            })
        } catch {
            log.error("Encode failed: \(error.localizedDescription)")
        }
    }

    private func receiveMessage(on connection: NWConnection, handler: @escaping (SyncMessage) -> Void) {
        // Read the 4-byte length prefix first
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let data, data.count == 4 else {
                if isComplete {
                    log.info("Connection closed by peer")
                    connection.cancel()
                }
                return
            }
            guard let length = frameLength(from: data) else { return }
            let payloadLength = Int(length)

            // Now read the JSON payload
            connection.receive(minimumIncompleteLength: payloadLength, maximumLength: payloadLength) { payload, _, _, error in
                guard let payload else {
                    if let error { log.error("Receive payload failed: \(error.localizedDescription)") }
                    return
                }
                do {
                    let message = try decodeMessage(from: payload)
                    handler(message)
                } catch {
                    log.error("Decode failed: \(error.localizedDescription)")
                }
            }
        }
    }
}
#endif
