/// Sync client — iPhone side of the companion sync protocol.
///
/// Discovers the Mac via Bonjour, connects over TCP, authenticates with HMAC
/// challenge-response, uploads recordings, and receives transcripts.

#if os(iOS) || os(macOS)
import Foundation
import Network
import CryptoKit
import SharedKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "sync-client")

/// Connection state for the sync client.
public enum SyncClientState: Sendable {
    case disconnected
    case browsing
    case connecting
    case authenticating
    case connected
    case syncing(current: Int, total: Int)
    case error(String)
}

/// Delegate for SyncClient events — implemented by the iOS app.
public protocol SyncClientDelegate: AnyObject, Sendable {
    func syncClientStateDidChange(_ state: SyncClientState)
    func syncClientDidReceiveTranscript(recordingID: String, transcript: TranscriptionResult)
}

/// iPhone sync client — discovers Mac and syncs recordings.
public final class SyncClient: @unchecked Sendable {
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private let pairingKey: SymmetricKey
    private let deviceName: String
    private let deviceID: String
    private let queue = DispatchQueue(label: "com.openplaudit.sync-client")
    public weak var delegate: SyncClientDelegate?
    public private(set) var state: SyncClientState = .disconnected {
        didSet { delegate?.syncClientStateDidChange(state) }
    }

    public init(pairingKey: SymmetricKey, deviceName: String, deviceID: String) {
        self.pairingKey = pairingKey
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    /// Start browsing for the Mac's sync service.
    public func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(for: .bonjour(type: syncServiceType, domain: nil), using: params)

        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                log.info("Browsing for \(syncServiceType)")
                self?.state = .browsing
            case .failed(let error):
                log.error("Browser failed: \(error.localizedDescription)")
                self?.state = .error(error.localizedDescription)
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            if let result = results.first {
                log.info("Found Mac: \(result.endpoint.debugDescription)")
                self.connectToEndpoint(result.endpoint)
            }
        }

        browser.start(queue: queue)
        self.browser = browser
    }

    /// Stop browsing and disconnect.
    public func stop() {
        browser?.cancel()
        browser = nil
        connection?.cancel()
        connection = nil
        state = .disconnected
    }

    /// Upload recordings to the connected Mac.
    public func uploadRecordings(_ recordings: [(meta: RecordingMeta, wavData: Data)]) {
        guard let connection else {
            log.warning("Cannot upload — not connected")
            return
        }
        // Send manifest
        let manifests = recordings.map(\.meta)
        sendMessage(.recordingManifest(manifests), on: connection)

        // Upload each recording in chunks
        for (i, recording) in recordings.enumerated() {
            state = .syncing(current: i + 1, total: recordings.count)
            uploadRecording(recording.meta, data: recording.wavData, on: connection)
        }
    }

    // MARK: - Connection

    private func connectToEndpoint(_ endpoint: NWEndpoint) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        state = .connecting

        connection.stateUpdateHandler = { [weak self] connState in
            switch connState {
            case .ready:
                log.info("Connected to Mac")
                self?.state = .authenticating
                self?.startHandshake(on: connection)
            case .failed(let error):
                log.error("Connection failed: \(error.localizedDescription)")
                self?.state = .error(error.localizedDescription)
                self?.connection = nil
            case .cancelled:
                self?.state = .disconnected
                self?.connection = nil
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func startHandshake(on connection: NWConnection) {
        // Send hello
        sendMessage(.hello(deviceName: deviceName, deviceID: deviceID), on: connection)

        // Wait for auth challenge
        receiveMessage(on: connection) { [weak self] message in
            guard let self else { return }
            guard case .authChallenge(let nonce) = message else {
                log.warning("Expected authChallenge, got \(String(describing: message))")
                self.state = .error("Unexpected server response")
                return
            }

            // Respond with HMAC
            let hmac = computeHMAC(data: nonce, key: self.pairingKey)
            self.sendMessage(.authResponse(hmac: hmac), on: connection)

            // Wait for ack
            self.receiveMessage(on: connection) { ackMsg in
                if case .ack = ackMsg {
                    log.info("Authenticated with Mac")
                    self.state = .connected
                    self.startReceiveLoop(on: connection)
                } else if case .error(let msg) = ackMsg {
                    log.error("Auth rejected: \(msg)")
                    self.state = .error("Authentication failed")
                    connection.cancel()
                } else {
                    log.warning("Unexpected post-auth message: \(String(describing: ackMsg))")
                }
            }
        }
    }

    private func startReceiveLoop(on connection: NWConnection) {
        receiveMessage(on: connection) { [weak self] message in
            guard let self else { return }
            switch message {
            case .transcriptReady(let recordingID, let transcript):
                log.info("Received transcript for \(recordingID)")
                self.sendMessage(.ack(messageID: recordingID), on: connection)
                self.delegate?.syncClientDidReceiveTranscript(recordingID: recordingID, transcript: transcript)
            case .ack(let messageID):
                log.debug("Server ack: \(messageID)")
            case .error(let msg):
                log.error("Server error: \(msg)")
                self.state = .error(msg)
            default:
                break
            }
            self.startReceiveLoop(on: connection)
        }
    }

    // MARK: - Upload

    private func uploadRecording(_ meta: RecordingMeta, data: Data, on connection: NWConnection) {
        var offset = 0
        while offset < data.count {
            let end = min(offset + uploadChunkSize, data.count)
            let chunk = data[offset..<end]
            sendMessage(.uploadChunk(recordingID: meta.id, offset: offset, data: Data(chunk)), on: connection)
            offset = end
        }
        let hash = sha256Hex(data)
        sendMessage(.uploadComplete(recordingID: meta.id, sha256: hash), on: connection)
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
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, isComplete, error in
            guard let data, data.count == 4 else {
                if isComplete {
                    log.info("Connection closed by peer")
                    connection.cancel()
                }
                return
            }
            guard let length = frameLength(from: data) else { return }
            let payloadLength = Int(length)

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
