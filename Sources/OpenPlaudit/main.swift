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
import os

private let log = Logger(subsystem: "com.openplaudit.app", category: "app")

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var engine: SyncEngine!
    private var settingsWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    // Menu item tags
    private let statusTag = 100
    private let syncButtonTag = 101
    private let cancelButtonTag = 102
    private let recentHeaderTag = 200

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = SyncEngine(config: loadConfigWithKeychain())

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "♪"

        buildMenu()

        // Observe status changes
        engine.$status.receive(on: RunLoop.main).sink { [weak self] status in
            self?.updateStatus(status)
        }.store(in: &cancellables)

        engine.$recentRecordings.receive(on: RunLoop.main).sink { [weak self] recordings in
            self?.updateRecordings(recordings)
        }.store(in: &cancellables)

        // Start auto-sync if configured
        if engine.config.sync.autoSyncEnabled {
            engine.startAutoSync(intervalMinutes: engine.config.sync.autoSyncIntervalMinutes)
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

        let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        statusLine.tag = statusTag
        menu.addItem(statusLine)

        menu.addItem(NSMenuItem.separator())

        let header = NSMenuItem(title: "No recent recordings", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.tag = recentHeaderTag
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem(title: "About OpenPlaudit", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenPlaudit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func updateStatus(_ status: SyncEngine.SyncStatus) {
        guard let menu = statusItem.menu else { return }
        let statusLine = menu.item(withTag: statusTag)
        let syncButton = menu.item(withTag: syncButtonTag)
        let cancelButton = menu.item(withTag: cancelButtonTag)

        switch status {
        case .idle:
            let connected = MainActor.assumeIsolated { engine.isConnected }
            statusItem.button?.title = connected ? "♪●" : "♪"
            statusLine?.title = connected ? "Connected" : "Idle"
            syncButton?.isEnabled = true
            cancelButton?.isHidden = true
        case .connecting:
            statusItem.button?.title = "♪…"
            statusLine?.title = "Connecting..."
            syncButton?.isEnabled = false
            cancelButton?.isHidden = false
        case .syncing(let current, let total):
            statusItem.button?.title = "♪↻"
            statusLine?.title = "Syncing \(current)/\(total)..."
            syncButton?.isEnabled = false
            cancelButton?.isHidden = false
        case .error(let msg):
            statusItem.button?.title = "♪⚠"
            statusLine?.title = "Error: \(msg)"
            syncButton?.isEnabled = true
            cancelButton?.isHidden = true
        }
    }

    private func updateRecordings(_ recordings: [SyncEngine.RecentRecording]) {
        guard let menu = statusItem.menu else { return }
        let headerIndex = menu.indexOfItem(withTag: recentHeaderTag)
        guard headerIndex >= 0 else { return }

        // Remove old recording items
        while let item = menu.item(withTag: recentHeaderTag) {
            menu.removeItem(item)
        }

        if recordings.isEmpty {
            let header = NSMenuItem(title: "No recent recordings", action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.tag = recentHeaderTag
            menu.insertItem(header, at: headerIndex)
        } else {
            let fmt = DateFormatter()
            fmt.dateStyle = .short
            fmt.timeStyle = .short

            for (i, rec) in recordings.prefix(5).enumerated() {
                let dur = rec.durationSeconds.map { "\(Int($0))s" } ?? ""
                let title = "\(fmt.string(from: rec.date))  \(dur)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.tag = recentHeaderTag
                menu.insertItem(item, at: headerIndex + i)
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = "OpenPlaudit Settings"
        w.center()
        w.contentView = NSHostingView(rootView: SettingsView(engine: engine))
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = w
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
