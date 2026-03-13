/// OpenPlaudit — macOS menubar app for PLAUD Note sync.
///
/// Pure AppKit entry point with NSStatusItem and NSMenu.
/// Uses main.swift (not @main) so we can control the run loop directly.
/// Must be launched as a .app bundle (via scripts/run-app.sh) for the
/// status item to render — LSUIElement=true in Info.plist hides the Dock icon.

import AppKit
import Combine
import SwiftUI
import SyncEngine
import TranscriptionKit
import MeetingKit
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "app")

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var engine: SyncEngine!
    var meetingEngine: MeetingEngine!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var durationTimer: Timer?

    // Menu item tags
    private let statusTag = 100
    private let syncButtonTag = 101
    private let cancelButtonTag = 102
    private let recentHeaderTag = 200
    private let recentItemBaseTag = 300
    private let meetingSeparatorTag = 400
    private let meetingRecordTag = 401
    private let meetingStatusTag = 402

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install a standard Edit menu so Cmd+V paste works in text fields.
        installEditMenu()

        let config = loadConfigWithKeychain()
        engine = SyncEngine(config: config)

        // Shared transcriber (model loaded once, reused by both engines)
        let transcriber = Transcriber(model: config.transcription.model)
        meetingEngine = MeetingEngine(config: config, transcriber: transcriber)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "OpenPlaudit")
            button.image?.isTemplate = true
        }

        buildMenu()

        // Observe sync status changes
        engine.$status.receive(on: RunLoop.main).sink { [weak self] status in
            self?.updateStatus(status)
        }.store(in: &cancellables)

        engine.$recentRecordings.receive(on: RunLoop.main).sink { [weak self] recordings in
            self?.updateRecordings(recordings)
        }.store(in: &cancellables)

        // Observe meeting recording state
        meetingEngine.$recordingState.receive(on: RunLoop.main).sink { [weak self] state in
            self?.updateMeetingStatus(state)
        }.store(in: &cancellables)

        // Start auto-sync if configured
        if engine.config.sync.autoSyncEnabled {
            engine.startAutoSync(intervalMinutes: engine.config.sync.autoSyncIntervalMinutes)
        }

        // Start meeting monitoring if configured
        if config.meeting.enabled && config.meeting.consentAcknowledged {
            meetingEngine.startMonitoring()
        }
    }

    private func buildMenu() {
        let menu = NSMenu()

        let syncItem = NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: "")
        syncItem.tag = syncButtonTag
        menu.addItem(syncItem)

        let cancelItem = NSMenuItem(title: "Cancel Sync", action: #selector(cancelSync), keyEquivalent: "")
        cancelItem.tag = cancelButtonTag
        cancelItem.isHidden = true
        menu.addItem(cancelItem)

        menu.addItem(NSMenuItem.separator())

        let statusLine = NSMenuItem(title: "Status: Idle", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.tag = statusTag
        menu.addItem(statusLine)

        // First-run guidance: show if device not configured
        let addr = MainActor.assumeIsolated { engine.config.device.address }
        if addr.isEmpty {
            let guideItem = NSMenuItem(title: "Open Settings to configure your PLAUD Note", action: #selector(showSettings), keyEquivalent: "")
            guideItem.tag = recentItemBaseTag + 99
            menu.addItem(guideItem)
        }

        // --- Meeting section ---
        let meetingSep = NSMenuItem.separator()
        meetingSep.tag = meetingSeparatorTag
        menu.addItem(meetingSep)

        let recordItem = NSMenuItem(title: "Record Meeting", action: #selector(toggleMeetingRecording), keyEquivalent: "")
        recordItem.tag = meetingRecordTag
        menu.addItem(recordItem)

        let meetingStatusLine = NSMenuItem(title: "Meeting: Idle", action: nil, keyEquivalent: "")
        meetingStatusLine.isEnabled = false
        meetingStatusLine.tag = meetingStatusTag
        menu.addItem(meetingStatusLine)

        menu.addItem(NSMenuItem.separator())

        let header = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = recentHeaderTag
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About OpenPlaudit", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenPlaudit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func setMenuBarIcon(_ symbolName: String, description: String) {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
            button.image?.isTemplate = true
        }
    }

    private func updateStatus(_ status: SyncEngine.SyncStatus) {
        guard let menu = statusItem.menu else { return }
        let statusLine = menu.item(withTag: statusTag)
        let syncButton = menu.item(withTag: syncButtonTag)
        let cancelButton = menu.item(withTag: cancelButtonTag)

        switch status {
        case .idle:
            let connected = MainActor.assumeIsolated { engine.isConnected }
            setMenuBarIcon(connected ? "waveform.circle.fill" : "waveform", description: connected ? "OpenPlaudit — Connected" : "OpenPlaudit")
            statusLine?.title = connected ? "Status: Connected" : "Status: Idle"
            syncButton?.isEnabled = true
            cancelButton?.isHidden = true
        case .connecting:
            setMenuBarIcon("antenna.radiowaves.left.and.right", description: "OpenPlaudit — Connecting")
            statusLine?.title = "Status: Connecting…"
            syncButton?.isEnabled = false
            cancelButton?.isHidden = false
        case .syncing(let current, let total):
            setMenuBarIcon("arrow.triangle.2.circlepath", description: "OpenPlaudit — Syncing")
            statusLine?.title = "Status: Syncing \(current)/\(total)…"
            syncButton?.isEnabled = false
            cancelButton?.isHidden = false
        case .cancelling:
            setMenuBarIcon("xmark.circle", description: "OpenPlaudit — Cancelling")
            statusLine?.title = "Status: Cancelling…"
            syncButton?.isEnabled = false
            cancelButton?.isHidden = true
        case .error(let msg):
            setMenuBarIcon("exclamationmark.triangle", description: "OpenPlaudit — Error")
            statusLine?.title = "Status: \(msg)"
            syncButton?.isEnabled = true
            cancelButton?.isHidden = true
        }
    }

    private func updateRecordings(_ recordings: [SyncEngine.RecentRecording]) {
        guard let menu = statusItem.menu else { return }
        let headerIndex = menu.indexOfItem(withTag: recentHeaderTag)
        guard headerIndex >= 0 else { return }

        // Remove old recording items (tagged recentHeaderTag)
        while let item = menu.item(withTag: recentHeaderTag) {
            menu.removeItem(item)
        }
        // Remove old numbered recording items
        for i in 0..<10 {
            if let item = menu.item(withTag: recentItemBaseTag + i) {
                menu.removeItem(item)
            }
        }

        // Re-insert header
        let header = NSMenuItem(title: "Recent Recordings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = recentHeaderTag
        let insertAt = min(headerIndex, menu.numberOfItems)
        menu.insertItem(header, at: insertAt)

        if recordings.isEmpty {
            let emptyItem = NSMenuItem(title: "  No recordings yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            emptyItem.tag = recentItemBaseTag
            menu.insertItem(emptyItem, at: insertAt + 1)
        } else {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short

            for (i, rec) in recordings.prefix(5).enumerated() {
                let dur = rec.durationSeconds.map { "\(Int($0))s" } ?? ""
                var title = "  \(fmt.string(from: rec.date))  \(dur)"
                if let preview = rec.transcriptPreview {
                    title += "\n    \(preview)"
                }
                let item = NSMenuItem(title: title, action: #selector(openRecording(_:)), keyEquivalent: "")
                item.tag = recentItemBaseTag + i
                item.representedObject = rec.filename
                menu.insertItem(item, at: insertAt + 1 + i)
            }
        }
    }

    @objc func syncNow() {
        Task { @MainActor in
            engine.startSync()
        }
    }

    @objc func cancelSync() {
        Task { @MainActor in
            engine.cancelSync()
        }
    }

    @objc func openRecording(_ sender: NSMenuItem) {
        guard let filename = sender.representedObject as? String else { return }
        let cfg = MainActor.assumeIsolated { engine.config }
        let dirs = getOutputDirs(cfg)
        // Try transcript first, fall back to audio
        let baseName = (filename as NSString).deletingPathExtension
        let jsonPath = dirs.transcripts.appendingPathComponent(baseName + ".json")
        let wavPath = dirs.audio.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: jsonPath.path) {
            NSWorkspace.shared.open(jsonPath)
        } else if FileManager.default.fileExists(atPath: wavPath.path) {
            NSWorkspace.shared.open(wavPath)
        }
    }

    @objc func toggleMeetingRecording() {
        Task { @MainActor in
            if case .recording = meetingEngine.recordingState {
                await meetingEngine.stopManualRecording()
            } else if let firstApp = meetingEngine.detectedApps.first {
                await meetingEngine.startManualRecording(app: firstApp)
            } else {
                // No meeting app detected — try recording anyway with first monitored non-browser app
                let monitored = meetingEngine.config.meeting.monitoredApps
                if let appID = monitored.first, let app = MeetingApp(rawValue: appID) {
                    await meetingEngine.startManualRecording(app: app)
                }
            }
        }
    }

    private func updateMeetingStatus(_ state: MeetingEngine.RecordingState) {
        guard let menu = statusItem.menu else { return }
        let statusLine = menu.item(withTag: meetingStatusTag)
        let recordButton = menu.item(withTag: meetingRecordTag)

        switch state {
        case .idle:
            stopDurationTimer()
            statusLine?.title = "Meeting: Idle"
            recordButton?.title = "Record Meeting"
            recordButton?.isEnabled = true
        case .monitoring:
            stopDurationTimer()
            statusLine?.title = "Meeting: Monitoring…"
            recordButton?.title = "Record Meeting"
            recordButton?.isEnabled = true
        case .recording(let app):
            setMenuBarIcon("record.circle.fill", description: "OpenPlaudit — Recording")
            statusLine?.title = "Recording: \(app)"
            let durStr = MainActor.assumeIsolated { meetingEngine.recordingDurationString }
            recordButton?.title = "Stop Recording (\(durStr))"
            recordButton?.isEnabled = true
            startDurationTimer()
        case .transcribing:
            stopDurationTimer()
            statusLine?.title = "Meeting: Transcribing…"
            recordButton?.title = "Record Meeting"
            recordButton?.isEnabled = false
        case .error(let msg):
            stopDurationTimer()
            statusLine?.title = "Meeting: \(msg)"
            recordButton?.title = "Record Meeting"
            recordButton?.isEnabled = true
        }

        // Update icon: recording takes priority over sync
        if case .recording = state {
            setMenuBarIcon("record.circle.fill", description: "OpenPlaudit — Recording")
        } else {
            let syncStatus = MainActor.assumeIsolated { engine.status }
            if case .idle = syncStatus {
                let connected = MainActor.assumeIsolated { engine.isConnected }
                setMenuBarIcon(connected ? "waveform.circle.fill" : "waveform",
                              description: connected ? "OpenPlaudit — Connected" : "OpenPlaudit")
            }
        }
    }

    private func startDurationTimer() {
        stopDurationTimer()
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self,
                  let menu = self.statusItem.menu,
                  let recordButton = menu.item(withTag: self.meetingRecordTag) else { return }
            let durStr = MainActor.assumeIsolated { self.meetingEngine.recordingDurationString }
            recordButton.title = "Stop Recording (\(durStr))"
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }

    /// Add a standard Edit menu with Cut/Copy/Paste/Select All so that
    /// keyboard shortcuts work in SwiftUI text fields (menubar-only apps
    /// don't get one automatically).
    private func installEditMenu() {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editMenuItem.submenu = editMenu

        if let mainMenu = NSApp.mainMenu {
            mainMenu.addItem(editMenuItem)
        } else {
            let mainMenu = NSMenu()
            mainMenu.addItem(editMenuItem)
            NSApp.mainMenu = mainMenu
        }
    }

    @objc func showAbout() {
        if let w = aboutWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "About OpenPlaudit"
        w.center()
        w.contentView = NSHostingView(rootView: AboutView())
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow = w
    }

    @objc func showSettings() {
        if let w = settingsWindow {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "Settings"
        w.center()
        w.contentView = NSHostingView(rootView: SettingsView(engine: engine, meetingEngine: meetingEngine))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = w
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
