import AppKit
import Combine
import SwiftUI

@main
final class ScreenVeilApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let lock = LockController()
    private var statusItem: NSStatusItem?
    private var statusObservation: AnyCancellable?
    private var settings: NSWindow?

    static func main() {
        let app = NSApplication.shared
        let delegate = ScreenVeilApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createApplicationMenu()
        createMenu()
        lock.start()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(restoreInput), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(restoreInput), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        showSettings()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        lock.refreshPermissions()
        lock.becameActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        lock.cancelShortcutRecording()
        lock.resignedActive()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        lock.cancelShortcutRecording()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        lock.updateCovers()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        lock.endLock(restoreFocus: false)
    }

    private func createApplicationMenu() {
        let main = NSMenu()
        let application = NSMenuItem()
        main.addItem(application)
        let menu = NSMenu(title: "ScreenVeil")
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Close Settings", action: #selector(closeSettings), keyEquivalent: "w").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit ScreenVeil", action: #selector(quit), keyEquivalent: "q").target = self
        application.submenu = menu
        NSApp.mainMenu = main
    }

    @objc private func closeSettings() {
        guard !lock.isLocked, !lock.isEngaging else { return }
        settings?.performClose(nil)
    }

    private func createMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.addItem(withTitle: "Lock Screen", action: #selector(lockScreen), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit ScreenVeil", action: #selector(quit), keyEquivalent: "q")
        menu.items.forEach { $0.target = self }
        item.menu = menu
        statusItem = item

        statusObservation = lock.$isLocked.sink { [weak item] locked in
            let symbol = locked ? "lock.rectangle.fill" : "lock.rectangle"
            item?.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ScreenVeil")
            item?.button?.toolTip = locked ? "ScreenVeil — Locked" : "ScreenVeil"
        }
    }

    @objc private func showSettings() {
        guard !lock.isLocked, !lock.isEngaging else { return }
        lock.refreshPermissions()
        lock.refreshKarabiner()
        NSApp.setActivationPolicy(.regular)
        if settings == nil {
            let host = NSHostingController(rootView: SettingsView(lock: lock))
            let window = NSWindow(contentViewController: host)
            window.title = "ScreenVeil"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "ScreenVeilSettings")
            window.toolbarStyle = .unified
            window.setContentSize(NSSize(width: 500, height: 450))
            window.delegate = self
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            settings = window
        }
        NSApp.activate()
        if settings?.isMiniaturized == true { settings?.deminiaturize(nil) }
        settings?.makeKeyAndOrderFront(nil)
    }

    @objc private func lockScreen() {
        lock.beginLock()
        if lock.message != nil { showSettings() }
    }

    @objc private func restoreInput() {
        lock.endLock(restoreFocus: false)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
