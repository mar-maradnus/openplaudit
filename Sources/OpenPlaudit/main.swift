/// OpenPlaudit — macOS menubar app for PLAUD Note sync.
///
/// Pure AppKit entry point with NSStatusItem and NSMenu.
/// Uses main.swift (not @main) so we can control the run loop directly.

import AppKit
import SwiftUI
import SyncEngine

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var engine: SyncEngine!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        engine = SyncEngine(config: loadConfig())

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "♪"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Sync Now", action: #selector(syncNow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let statusItem = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        statusItem.tag = 100
        menu.addItem(statusItem)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit OpenPlaudit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        self.statusItem.menu = menu

        // Hide Dock icon after a short delay so the status item is established
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @objc func syncNow() {
        Task { @MainActor in
            try? await engine.runSync()
        }
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
