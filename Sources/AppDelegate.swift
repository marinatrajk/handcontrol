import AppKit
import AVFoundation
import Carbon.HIToolbox

/// The menu bar app: wires the camera, the gesture engine and the mouse together.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tracker = HandTracker()
    private let input = InputController()
    private let engine = GestureEngine()

    private var statusItem: NSStatusItem!
    private var toggleItem: NSMenuItem!
    private var previewItem: NSMenuItem!
    private var accessItem: NSMenuItem!
    private var cameraItem: NSMenuItem!
    private var preview: PreviewWindow?
    private var hotKey: HotKey?

    private var enabled = true
    private var cameraProblem: String?
    private var mode = HandMode.none
    private var flashUntil = 0.0
    private var currentIcon = ""

    private var showPreviewSetting: Bool {
        get { UserDefaults.standard.object(forKey: "showCamera") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showCamera") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        buildMenu()
        screenChanged()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        hotKey = HotKey(keyCode: kVK_ANSI_H, modifiers: controlKey | optionKey) { [weak self] in self?.toggle() }

        tracker.onFrame = { [weak self] pose, time in self?.handle(pose, at: time) }
        tracker.onError = { [weak self] message in
            self?.cameraProblem = message
            self?.refresh()
        }

        if !InputController.hasAccess { InputController.askForAccess() }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
        startCamera()
        if showPreviewSetting { showPreview() }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave the mouse button held down.
        tracker.queue.sync { engine.reset().forEach(input.perform) }
        usleep(50_000)
    }

    // MARK: - Camera frames (tracker queue)

    private func handle(_ pose: HandPose?, at time: Double) {
        guard enabled else { return }
        let actions = engine.update(pose, at: time, pointer: input.pointer)
        if InputController.hasAccess { actions.forEach(input.perform) }
        let status = engine.status
        DispatchQueue.main.async { [self] in
            if actions.contains(where: { if case .click = $0 { return true } else { return false } }) {
                flashUntil = CACurrentMediaTime() + 0.3
            }
            if actions.contains(.closeWindow) {
                Toast.shared.show(InputController.hasAccess ? InputController.closeFrontWindow()
                                                            : "Allow Accessibility to close windows")
            }
            mode = status.mode
            updateIcon()
            preview?.show(pose, status, enabled: enabled)
        }
    }

    // MARK: - Actions

    @objc private func toggle() {
        enabled.toggle()
        if enabled {
            startCamera()
        } else {
            tracker.stop()
            tracker.queue.async { [self] in engine.reset().forEach(input.perform) }
            mode = .none
            preview?.show(nil, EngineStatus(), enabled: false)
        }
        Toast.shared.show(enabled ? "Hand control on" : "Hand control off")
        refresh()
    }

    @objc private func togglePreview() {
        if preview?.isVisible == true {
            preview?.close()
        } else {
            showPreview()
        }
        refresh()
    }

    private func showPreview() {
        if preview == nil {
            preview = PreviewWindow(session: tracker.session, region: engine.config.region)
            preview?.onClose = { [weak self] in
                self?.showPreviewSetting = false
                self?.refresh()
            }
        }
        preview?.showWindow(nil)
        preview?.window?.orderFrontRegardless()
        showPreviewSetting = true
    }

    @objc private func openAccessibilitySettings() {
        InputController.askForAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openCameraSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func screenChanged() {
        let size = CGDisplayBounds(CGMainDisplayID()).size
        tracker.queue.async { [self] in engine.config.screen = size }
    }

    private func startCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            cameraProblem = nil
            tracker.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { [self] in
                    if granted { cameraProblem = nil; tracker.start() } else { cameraProblem = "Camera access was denied" }
                    refresh()
                }
            }
        default:
            cameraProblem = "Camera access is off"
        }
    }

    // MARK: - Menu and icon

    private func buildMenu() {
        let menu = NSMenu()
        menu.delegate = self

        toggleItem = NSMenuItem(title: "Hand Control On", action: #selector(toggle), keyEquivalent: "h")
        toggleItem.keyEquivalentModifierMask = [.control, .option]
        menu.addItem(toggleItem)
        previewItem = NSMenuItem(title: "Show Camera", action: #selector(togglePreview), keyEquivalent: "")
        menu.addItem(previewItem)
        menu.addItem(.separator())

        accessItem = NSMenuItem(title: "", action: #selector(openAccessibilitySettings), keyEquivalent: "")
        menu.addItem(accessItem)
        cameraItem = NSMenuItem(title: "", action: #selector(openCameraSettings), keyEquivalent: "")
        menu.addItem(cameraItem)
        menu.addItem(.separator())

        let gestures = NSMenu()
        for line in [
            "Move your hand: the pointer follows your knuckles",
            "Pinch thumb and index: click (twice for double-click)",
            "Three fingers up: grab and drag, open your hand to drop",
            "Flat open hand: the pointer parks",
            "Open hand, swipe down: close the front window",
            "⌃⌥H: turn hand control on or off",
        ] {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            gestures.addItem(item)
        }
        let gesturesItem = NSMenuItem(title: "Gestures", action: nil, keyEquivalent: "")
        gesturesItem.submenu = gestures
        menu.addItem(gesturesItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit HandControl", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil { item.target = self }
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    private func refresh() {
        let access = InputController.hasAccess
        toggleItem.title = enabled ? "Hand Control On" : "Hand Control Off"
        toggleItem.state = enabled ? .on : .off
        previewItem.title = preview?.isVisible == true ? "Hide Camera" : "Show Camera"
        accessItem.title = access ? "Accessibility: allowed" : "Allow Accessibility (needed to move the pointer)…"
        accessItem.isEnabled = !access
        cameraItem.title = cameraProblem.map { "\($0) · open settings…" } ?? "Camera: allowed"
        cameraItem.isEnabled = cameraProblem != nil
        updateIcon()
    }

    private func updateIcon() {
        let symbol: String
        if !enabled {
            symbol = "hand.raised.slash"
        } else if !InputController.hasAccess || cameraProblem != nil {
            symbol = "exclamationmark.triangle"
        } else if CACurrentMediaTime() < flashUntil {
            symbol = "hand.pinch.fill"
        } else {
            switch mode {
            case .none: symbol = "hand.raised"
            case .point: symbol = "hand.point.up.left.fill"
            case .open: symbol = "hand.raised.fill"
            case .drag: symbol = "hand.draw.fill"
            }
        }
        guard symbol != currentIcon, let button = statusItem.button else { return }
        currentIcon = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "HandControl")
            ?? NSImage(systemSymbolName: "hand.raised", accessibilityDescription: "HandControl")
        image?.isTemplate = true
        button.image = image
    }
}
