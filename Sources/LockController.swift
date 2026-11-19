import AppKit
import Carbon
import CoreGraphics
import SwiftUI

final class LockController: ObservableObject {
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var shortcutAvailable = false
    @Published private(set) var isLocked = false
    @Published private(set) var message: String?
    @Published private(set) var currentShortcut: Shortcut
    @Published private(set) var isRecordingShortcut = false
    @Published private(set) var shortcutError: String?
    @Published private(set) var karabinerCoverage = KarabinerConfiguration.Coverage()
    @Published private(set) var karabinerError: String?
    @Published var showUnlockHint: Bool {
        didSet { UserDefaults.standard.set(showUnlockHint, forKey: "showUnlockHint") }
    }

    private var shortcut: GlobalShortcut?
    private var shortcutMonitor: Any?
    private let karabinerConfiguration = KarabinerConfiguration()
    private let karabinerLease = KarabinerLease()
    private var lockRequest: UUID?
    private var leaseActive = false
    private var leaseTimer: Timer?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var permissionTimer: Timer?
    private var healthTimer: Timer?
    private var activationTimeout: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var cursorDisconnected = false
    private var cursorHidden = false
    private var unlockArmed = false
    private var unlockQueued = false
    private var covers: [CoverWindow] = []

    var isEngaging: Bool { lockRequest != nil && !isLocked }
    var permissionsGranted: Bool { accessibility && inputMonitoring }
    var ready: Bool { permissionsGranted && shortcutAvailable }
    var karabinerAvailable: Bool { KarabinerLease.installed }
    var karabinerSupported: Bool { KarabinerLease.supportsConditions }

    init() {
        let defaults = UserDefaults.standard
        showUnlockHint = defaults.object(forKey: "showUnlockHint") as? Bool ?? true
        currentShortcut = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
            ?? .standard
    }

    func start() {
        refreshPermissions()
        refreshKarabiner()
        bindCurrentShortcut()
        // Permissions can change in System Settings without activating ScreenVeil.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, !self.isLocked else { return }
            self.refreshPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    func refreshPermissions() {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        if self.accessibility != accessibility { self.accessibility = accessibility }
        if self.inputMonitoring != inputMonitoring { self.inputMonitoring = inputMonitoring }
    }

    func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openPrivacyPane("Privacy_Accessibility")
    }

    func requestInputMonitoring() {
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        openPrivacyPane("Privacy_ListenEvent")
    }

    private func openPrivacyPane(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func registration(for shortcut: Shortcut) -> GlobalShortcut? {
        GlobalShortcut(shortcut: shortcut) { [weak self] in
            // Carbon may run this callback inside its own registered handler.
            DispatchQueue.main.async {
                guard let self, !self.isRecordingShortcut else { return }
                if self.isLocked { self.queueUnlock() }
                else { self.beginLock() }
            }
        }
    }

    private func bindCurrentShortcut() {
        shortcut = registration(for: currentShortcut)
        shortcutAvailable = shortcut != nil
    }

    func beginShortcutRecording() {
        guard !isLocked, !isEngaging, !isRecordingShortcut else { return }
        shortcut = nil
        shortcutError = nil
        isRecordingShortcut = true
        shortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if !event.isARepeat { self.recordShortcut(event) }
            return nil
        }
    }

    func cancelShortcutRecording() {
        guard isRecordingShortcut else { return }
        stopShortcutRecording()
        shortcutError = nil
        bindCurrentShortcut()
    }

    private func stopShortcutRecording() {
        if let shortcutMonitor { NSEvent.removeMonitor(shortcutMonitor) }
        shortcutMonitor = nil
        isRecordingShortcut = false
    }

    private func recordShortcut(_ event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        if event.keyCode == kVK_Escape, modifiers.isEmpty {
            cancelShortcutRecording()
            return
        }
        guard let candidate = Shortcut.recorded(from: event) else {
            shortcutError = "Use Command, Option or Control with a key that macOS doesn’t reserve."
            return
        }
        guard let binding = registration(for: candidate) else {
            shortcutError = "That shortcut is already in use. Try another one."
            return
        }
        shortcut = binding
        currentShortcut = candidate
        shortcutAvailable = true
        shortcutError = nil
        message = nil
        if let data = try? JSONEncoder().encode(candidate) {
            UserDefaults.standard.set(data, forKey: "shortcut")
        }
        stopShortcutRecording()
    }

    func refreshKarabiner() {
        guard karabinerAvailable else { return }
        do {
            karabinerCoverage = try karabinerConfiguration.coverage()
        } catch {
            karabinerError = error.localizedDescription
        }
    }

    func setKarabinerProtection(_ enabled: Bool) {
        do {
            karabinerCoverage = try karabinerConfiguration.setEnabled(enabled)
            karabinerError = nil
        } catch {
            karabinerError = error.localizedDescription
        }
    }

    func beginLock() {
        guard !isLocked, !isEngaging, !isRecordingShortcut else { return }
        refreshPermissions()
        guard ready else {
            message = shortcutAvailable ? "Allow both permissions to use the shortcut."
                : "Choose an available global shortcut."
            return
        }
        guard !IsSecureEventInputEnabled() else {
            message = "Close the active secure input field and try again."
            return
        }
        message = nil
        let request = UUID()
        lockRequest = request
        previousApp = NSWorkspace.shared.frontmostApplication
        refreshKarabiner()
        guard karabinerCoverage.isEnabled, karabinerAvailable, karabinerSupported else {
            activateForLock()
            return
        }

        // Arm Karabiner's rules before showing the overlay so script actions
        // cannot outrun the Quartz event filter.
        leaseActive = true
        karabinerLease.update(locked: true) { [weak self] success in
            guard let self, self.lockRequest == request else { return }
            if success { self.activateForLock() }
            else { self.endLock(reason: "ScreenVeil couldn’t reach Karabiner. Check that Karabiner-Elements is running.") }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.lockRequest == request, !self.isLocked, self.activationTimeout == nil else { return }
            self.endLock(reason: "Karabiner didn’t respond. Try again.")
        }
    }

    private func activateForLock() {
        if NSApp.isActive {
            lockInForeground()
            return
        }

        let timeout = DispatchWorkItem { [weak self] in
            self?.endLock(reason: "ScreenVeil could not become the active app.")
        }
        activationTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout)
        NSApp.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.activationTimeout != nil, !NSApp.isActive else { return }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        }
    }

    func becameActive() {
        if activationTimeout != nil {
            lockInForeground()
        } else if isLocked {
            _ = CGAssociateMouseAndMouseCursorPosition(0)
            covers.first { $0.frame == NSScreen.main?.frame }?.makeKey()
        }
    }

    func resignedActive() {
        // Another process can request focus independently of keyboard events.
        // Preserve the tap and overlay while returning focus to the cover.
        guard isLocked else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isLocked, !NSApp.isActive, !IsSecureEventInputEnabled() else { return }
            self.covers.forEach { $0.orderFrontRegardless() }
            NSApp.activate()
        }
    }

    private func lockInForeground() {
        activationTimeout?.cancel()
        activationTimeout = nil
        guard !NSScreen.screens.isEmpty, !IsSecureEventInputEnabled(), installTap() else {
            endLock(reason: "macOS could not start input filtering. Check permissions and reopen ScreenVeil.")
            return
        }
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else {
            endLock(reason: "macOS could not freeze the pointer.")
            return
        }
        cursorDisconnected = true
        cursorHidden = CGDisplayHideCursor(CGMainDisplayID()) == .success
        isLocked = true
        updateCovers()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.checkLockHealth()
        }
        RunLoop.main.add(timer, forMode: .common)
        healthTimer = timer
        if leaseActive {
            let leaseTimer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                guard let self, self.isLocked, self.leaseActive else { return }
                self.karabinerLease.update(locked: true)
            }
            RunLoop.main.add(leaseTimer, forMode: .common)
            self.leaseTimer = leaseTimer
        }
    }

    func endLock(reason: String? = nil, restoreFocus: Bool = true) {
        let wasLocked = isLocked
        lockRequest = nil
        leaseTimer?.invalidate()
        leaseTimer = nil
        if leaseActive {
            karabinerLease.update(locked: false)
            leaseActive = false
        }
        activationTimeout?.cancel()
        activationTimeout = nil
        healthTimer?.invalidate()
        healthTimer = nil
        unlockArmed = false
        unlockQueued = false
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tapSource = nil
        tap = nil
        if cursorDisconnected {
            _ = CGAssociateMouseAndMouseCursorPosition(1)
            cursorDisconnected = false
        }
        if cursorHidden {
            _ = CGDisplayShowCursor(CGMainDisplayID())
            cursorHidden = false
        }
        covers.forEach { $0.orderOut(nil) }
        covers.removeAll()
        if wasLocked { isLocked = false }
        if let reason { message = reason }
        if restoreFocus, let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(options: [])
        }
        previousApp = nil
    }

    func updateCovers() {
        guard isLocked else { return }
        let screens = NSScreen.screens
        guard let primary = NSScreen.main ?? screens.first else {
            endLock(reason: "Input restored after the displays disconnected.")
            return
        }
        let newCovers = screens.map {
            CoverWindow(screen: $0, unlockHint: showUnlockHint ? currentShortcut.label : nil)
        }
        newCovers.forEach { $0.orderFrontRegardless() }
        newCovers.first { $0.frame == primary.frame }?.makeKey()
        covers.forEach { $0.orderOut(nil) }
        covers = newCovers
    }

    private func installTap() -> Bool {
        let eventTypes: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .mouseMoved,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel
        ]
        let systemDefined = CGEventMask(1) << NSEvent.EventType.systemDefined.rawValue
        let mask = eventTypes.reduce(systemDefined) { $0 | (CGEventMask(1) << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: { _, type, event, pointer in
            guard let pointer else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<LockController>.fromOpaque(pointer).takeUnretainedValue()
            return controller.filter(type, event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }

        self.tap = tap
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    private func filter(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isLocked else { return }
                self.endLock(reason: "Input restored after macOS interrupted filtering.")
            }
            return Unmanaged.passUnretained(event)
        }
        guard isLocked else { return Unmanaged.passUnretained(event) }
        if type == .keyDown, currentShortcut.matches(event) {
            unlockArmed = true
        }
        if type == .keyUp, unlockArmed,
           event.getIntegerValueField(.keyboardEventKeycode) == Int64(currentShortcut.key) {
            queueUnlock()
        }
        return nil
    }

    private func queueUnlock() {
        guard !unlockQueued else { return }
        unlockQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.unlockQueued else { return }
            self.endLock()
        }
    }

    private func checkLockHealth() {
        guard let tap, CGEvent.tapIsEnabled(tap: tap), !IsSecureEventInputEnabled(),
              AXIsProcessTrusted(), CGPreflightListenEventAccess() else {
            endLock(reason: "Input restored after macOS interrupted filtering.")
            return
        }
        // Recover if the matching key went up without a delivered key-up event.
        if unlockArmed, !CGEventSource.keyState(.hidSystemState, key: CGKeyCode(currentShortcut.key)) {
            queueUnlock()
        }
    }
}

private final class CoverWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen, unlockHint: String?) {
        super.init(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.appearance = NSAppearance(named: .darkAqua)

        let overlay = NSHostingView(rootView: ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(spacing: 15) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 32, weight: .medium))
                    .accessibilityHidden(true)
                Text("Screen locked")
                    .font(.system(size: 29, weight: .semibold))
                if let unlockHint {
                    Text("Press \(unlockHint) to unlock")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.77))
                }
            }
            .foregroundStyle(.white)
        })
        overlay.frame = blur.bounds
        overlay.autoresizingMask = [.width, .height]
        blur.addSubview(overlay)
        contentView = blur
    }

    // Events outside the Quartz filter, such as window-local gestures,
    // must not interact with the cover or any control behind it.
    override func sendEvent(_ event: NSEvent) {}
}
