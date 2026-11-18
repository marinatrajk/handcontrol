import AppKit

/// A short message near the bottom of the screen ("Closed Safari window", "Hand control off").
/// It never takes focus or catches clicks.
final class Toast {
    static let shared = Toast()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private var hideWork: DispatchWorkItem?

    func show(_ text: String) {
        let panel = self.panel ?? makePanel()
        label.stringValue = text
        label.sizeToFit()
        let size = NSSize(width: ceil(label.frame.width) + 40, height: 42)
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 90, width: size.width, height: size.height), display: true)
        }
        label.setFrameOrigin(NSPoint(x: 20, y: (size.height - label.frame.height) / 2))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; panel?.animator().alphaValue = 0 },
                                                 completionHandler: { panel?.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: work)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .labelColor
        background.addSubview(label)
        panel.contentView = background
        self.panel = panel
        return panel
    }
}
