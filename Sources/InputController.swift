import AppKit
import ApplicationServices

/// Turns gesture actions into real mouse events, and closes windows through the Accessibility API.
/// Both need HandControl to be allowed under System Settings › Privacy & Security › Accessibility.
final class InputController {
    private let queue = DispatchQueue(label: "handcontrol.input", qos: .userInteractive)
    private let source = CGEventSource(stateID: .hidSystemState)
    private var dragging = false
    private var clicks = 0
    private var lastClickTime = 0.0
    private var lastClickPoint = CGPoint.zero

    init() {
        // Keep the trackpad and mouse working while we post events.
        source?.localEventsSuppressionInterval = 0
    }

    static var hasAccess: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that sends you to the Accessibility settings.
    static func askForAccess() {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Where the pointer is now, in global screen points (top-left origin).
    var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    /// Performs a pointer action. Window closing is done separately on the main thread with `closeFrontWindow()`.
    func perform(_ action: HandAction) {
        queue.async { [self] in
            switch action {
            case .move(let p):
                post(dragging ? .leftMouseDragged : .mouseMoved, at: p)
            case .click(let p):
                click(at: p)
            case .dragBegin(let p):
                dragging = true
                post(.leftMouseDown, at: p, clickState: 1)
            case .dragEnd(let p):
                dragging = false
                post(.leftMouseUp, at: p, clickState: 1)
            case .closeWindow:
                break
            }
        }
    }

    private func click(at p: CGPoint) {
        // Apps only see a double-click if the click count is set on the event.
        let now = ProcessInfo.processInfo.systemUptime
        let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 12
        clicks = now - lastClickTime < NSEvent.doubleClickInterval && near ? min(clicks + 1, 3) : 1
        lastClickTime = now
        lastClickPoint = p
        post(.leftMouseDown, at: p, clickState: clicks)
        usleep(12_000)
        post(.leftMouseUp, at: p, clickState: clicks)
    }

    private func post(_ type: CGEventType, at p: CGPoint, clickState: Int = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left) else { return }
        if clickState > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState)) }
        event.post(tap: .cghidEventTap)
    }

    /// Presses the close button on the front app's focused window. Returns a short message to show on screen.
    static func closeFrontWindow() -> String {
        guard let app = NSWorkspace.shared.frontmostApplication else { return "No window to close" }
        let name = app.localizedName ?? "That app"
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = element(axApp, kAXFocusedWindowAttribute) ?? element(axApp, kAXMainWindowAttribute) else {
            return "\(name) has no window open"
        }
        guard let button = element(window, kAXCloseButtonAttribute) else {
            return "This \(name) window can't be closed"
        }
        return AXUIElementPerformAction(button, kAXPressAction as CFString) == .success
            ? "Closed \(name) window"
            : "Couldn't close the \(name) window"
    }

    private static func element(_ parent: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(parent, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
