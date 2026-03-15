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
    private var pendingUploads: [String: URL] = [:]  // recordingID → temp file URL
    private var pendingUploadSizes: [String: Int] = [:]
    private var receiveBuffer = Data()
    private var isAuthenticated = false

    /// Maximum allowed frame size (16 MB — generous for JSON + 64KB chunk).
    private static let maxFrameSize: UInt32 = 16 * 1024 * 1024
    /// Maximum allowed upload size per recording (500 MB).
    private static let maxUploadSize = 500 * 1024 * 1024
    /// Maximum concurrent pending uploads.
    private static let maxPendingUploads = 10

    /// Sanitise a network-sourced identifier for safe use in file paths.
    private static func sanitisePathComponent(_ input: String) -> String? {
        let sanitised = input.replacingOccurrences(of: "[^a-zA-Z0-9_\\-]", with: "_", options: .regularExpression)
        guard !sanitised.isEmpty, sanitised != ".", sanitised != ".." else { return nil }
        return sanitised
    }

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
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            activeConnection?.cancel()
            activeConnection = nil
            for (id, _) in pendingUploads { cleanupPendingUpload(id) }
        }
    }

    private func cleanupPendingUpload(_ id: String) {
        if let url = pendingUploads.removeValue(forKey: id) {
            try? FileManager.default.removeItem(at: url)
        }
        pendingUploadSizes.removeValue(forKey: id)
    }

    /// Send a transcript back to the connected companion.
    public func sendTranscript(recordingID: String, transcript: TranscriptionResult) {
        queue.async { [self] in
            guard let connection = activeConnection else { return }
            let message = SyncMessage.transcriptReady(recordingID: recordingID, transcript: transcript)
            sendMessage(message, on: connection)
        }
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
                self?.isAuthenticated = false
                self?.startAuthChallenge(on: connection)
                // Auto-cancel unauthenticated connections after 10 seconds
                self?.queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                    guard let self, self.activeConnection === connection, !self.isAuthenticated else { return }
                    log.warning("Auth timeout — cancelling unauthenticated connection")
                    connection.cancel()
                }
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
        // Protocol: client sends hello → server sends challenge → client sends authResponse → server sends ack
        receiveMessage(on: connection) { [weak self] message in
            guard let self else { return }
            guard case .hello(let name, let deviceID, _) = message else {
                log.warning("Expected hello, got \(String(describing: message))")
                connection.cancel()
                return
            }
            log.info("Received hello from \(name)")

            let nonce = generateNonce()
            self.sendMessage(.authChallenge(nonce: nonce), on: connection)

            // Server also proves it holds the key: HMAC over reversed nonce
            let serverProof = computeHMAC(data: Data(nonce.reversed()), key: self.pairingKey)

            self.receiveMessage(on: connection) { authMsg in
                self.handleAuthResponse(authMsg, nonce: nonce, serverProof: serverProof, deviceName: name, deviceID: deviceID, on: connection)
            }
        }
    }

    private func handleAuthResponse(_ message: SyncMessage, nonce: Data, serverProof: Data, deviceName: String, deviceID: String, on connection: NWConnection) {
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

        // Mutual auth: server proves it holds the key by sending HMAC over reversed nonce
        log.info("Companion authenticated: \(deviceName)")
        isAuthenticated = true
        sendMessage(.authResponse(hmac: serverProof), on: connection)
        delegate?.syncServerDidConnect(deviceName: deviceName, deviceID: deviceID)
        startReceiveLoop(on: connection)
    }

    private func startReceiveLoop(on connection: NWConnection) {
        receiveMessage(on: connection) { [weak self] message in
            guard let self else { return }
            let shouldContinue = self.handleMessage(message, on: connection)
            if shouldContinue {
                self.startReceiveLoop(on: connection)
            }
        }
    }

    /// Returns true if the receive loop should continue.
    @discardableResult
    private func handleMessage(_ message: SyncMessage, on connection: NWConnection) -> Bool {
        switch message {
        case .recordingManifest(let manifests):
            let needed = manifests.filter { meta in
                guard let safeName = Self.sanitisePathComponent(meta.id) else { return false }
                let path = self.outputDir.appendingPathComponent("\(safeName).wav")
                return !FileManager.default.fileExists(atPath: path.path)
            }
            let neededIDs = needed.map(\.id)
            log.info("Manifest received: \(manifests.count) recordings, \(neededIDs.count) needed")
            sendMessage(.ack(messageID: "need:\(neededIDs.joined(separator: ","))"), on: connection)

        case .uploadChunk(let recordingID, let offset, let data):
            guard let safeID = Self.sanitisePathComponent(recordingID) else {
                sendMessage(.error("Invalid recording ID"), on: connection)
                return false
            }
            // Create temp file for new upload
            if pendingUploads[safeID] == nil {
                guard pendingUploads.count < Self.maxPendingUploads else {
                    sendMessage(.error("Too many concurrent uploads"), on: connection)
                    return false
                }
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("upload-\(safeID).tmp")
                FileManager.default.createFile(atPath: tempURL.path, contents: nil)
                pendingUploads[safeID] = tempURL
                pendingUploadSizes[safeID] = 0
            }
            // Validate offset matches current size
            let currentSize = pendingUploadSizes[safeID] ?? 0
            guard offset == currentSize else {
                log.error("Offset mismatch for \(safeID): expected \(currentSize), got \(offset)")
                sendMessage(.error("Offset mismatch for \(recordingID)"), on: connection)
                return false
            }
            // Enforce size limit
            guard currentSize + data.count <= Self.maxUploadSize else {
                log.error("Upload size limit exceeded for \(safeID)")
                cleanupPendingUpload(safeID)
                sendMessage(.error("Upload too large"), on: connection)
                return false
            }
            // Append to temp file
            if let fileHandle = try? FileHandle(forWritingTo: pendingUploads[safeID]!) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                fileHandle.closeFile()
                pendingUploadSizes[safeID] = currentSize + data.count
            }

        case .uploadComplete(let recordingID, let expectedSHA):
            guard let safeID = Self.sanitisePathComponent(recordingID),
                  let tempURL = pendingUploads.removeValue(forKey: safeID) else {
                sendMessage(.error("No pending upload for \(recordingID)"), on: connection)
                return true
            }
            pendingUploadSizes.removeValue(forKey: safeID)
            do {
                let uploadData = try Data(contentsOf: tempURL)
                try? FileManager.default.removeItem(at: tempURL)

                let actualSHA = sha256Hex(uploadData)
                guard actualSHA == expectedSHA else {
                    log.error("SHA256 mismatch for \(safeID): expected \(expectedSHA), got \(actualSHA)")
                    sendMessage(.error("SHA256 mismatch for \(recordingID)"), on: connection)
                    return true
                }
                try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
                let wavPath = outputDir.appendingPathComponent("\(safeID).wav")
                // Verify resolved path is inside outputDir
                guard wavPath.standardizedFileURL.path.hasPrefix(outputDir.standardizedFileURL.path) else {
                    sendMessage(.error("Invalid recording ID"), on: connection)
                    return true
                }
                try uploadData.write(to: wavPath, options: .atomic)
                log.info("Recording \(safeID) saved (\(uploadData.count) bytes)")
                sendMessage(.ack(messageID: recordingID), on: connection)
                delegate?.syncServerDidReceiveRecording(id: recordingID, wavPath: wavPath)
            } catch {
                log.error("Failed to save recording \(safeID): \(error.localizedDescription)")
                sendMessage(.error("Failed to save: \(error.localizedDescription)"), on: connection)
            }

        case .ack:
            break // Client acknowledged our message

        case .error(let msg):
            log.error("Client error: \(msg)")
            return false // Stop the loop

        default:
            log.warning("Unexpected message: \(String(describing: message))")
        }
        return true
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
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let data, data.count == 4 else {
                if isComplete {
                    log.info("Connection closed by peer")
                    connection.cancel()
                }
                return
            }
            guard let length = frameLength(from: data) else { return }
            guard length <= Self.maxFrameSize else {
                log.error("Frame too large: \(length) bytes (max \(Self.maxFrameSize))")
                connection.cancel()
                return
            }
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
