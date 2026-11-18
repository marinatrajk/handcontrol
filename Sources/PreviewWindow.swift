import AppKit
import AVFoundation

/// A small floating window with the camera picture, the tracked hand drawn on top, and what the engine sees.
final class PreviewWindow: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let videoLayer: AVCaptureVideoPreviewLayer
    private let overlay = OverlayView()
    private var mirrored = false

    init(session: AVCaptureSession, region: CGRect) {
        videoLayer = AVCaptureVideoPreviewLayer(session: session)
        videoLayer.videoGravity = .resizeAspect

        let size = NSSize(width: 448, height: 252)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "HandControl"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.black.cgColor
        let video = NSView(frame: content.bounds)
        video.layer = videoLayer
        video.wantsLayer = true
        video.autoresizingMask = [.width, .height]
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.region = region
        content.addSubview(video)
        content.addSubview(overlay)
        window.contentView = content

        if let area = NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(NSPoint(x: area.maxX - window.frame.width - 16, y: area.maxY - 16))
        }
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    var isVisible: Bool { window?.isVisible ?? false }

    func show(_ pose: HandPose?, _ status: EngineStatus, enabled: Bool) {
        guard isVisible else { return }
        // Show the picture like a mirror, matching how the hand is tracked.
        if !mirrored, let connection = videoLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
            mirrored = true
        }
        overlay.pose = pose
        overlay.status = status
        overlay.enabled = enabled
        overlay.needsDisplay = true
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}

private final class OverlayView: NSView {
    var pose: HandPose?
    var status = EngineStatus()
    var region = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.53)
    var enabled = true

    override var isFlipped: Bool { true }

    private static let bones: [(Joint, Joint)] = {
        var bones: [(Joint, Joint)] = [(.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
                                       (.indexMCP, .middleMCP), (.middleMCP, .ringMCP), (.ringMCP, .littleMCP),
                                       (.wrist, .indexMCP), (.wrist, .littleMCP)]
        for f in Finger.allCases {
            bones += [(f.mcp, f.pip), (f.pip, f.dip), (f.dip, f.tip)]
        }
        return bones
    }()

    override func draw(_ dirtyRect: NSRect) {
        let aspect = pose?.aspect ?? 16.0 / 9.0
        let video = AVMakeRect(aspectRatio: CGSize(width: aspect, height: 1), insideRect: bounds)
        func map(_ p: CGPoint) -> CGPoint {
            CGPoint(x: video.minX + p.x * video.width, y: video.minY + p.y * video.height)
        }

        // The area that maps onto the screen.
        let area = NSBezierPath(roundedRect: CGRect(x: video.minX + region.minX * video.width,
                                                    y: video.minY + region.minY * video.height,
                                                    width: region.width * video.width,
                                                    height: region.height * video.height),
                                xRadius: 8, yRadius: 8)
        area.lineWidth = 1.5
        area.setLineDash([6, 5], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.55).setStroke()
        area.stroke()

        if let pose, enabled {
            let color = status.pinched ? NSColor.systemPink : modeColor
            let bones = NSBezierPath()
            for (a, b) in Self.bones {
                bones.move(to: map(pose[a]))
                bones.line(to: map(pose[b]))
            }
            bones.lineWidth = 3
            bones.lineCapStyle = .round
            color.withAlphaComponent(0.9).setStroke()
            bones.stroke()

            NSColor.white.setFill()
            for joint in Joint.allCases {
                let p = map(pose[joint])
                NSBezierPath(ovalIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
            }
            // The point the pointer follows.
            let k = map(pose.knuckles)
            color.setFill()
            NSBezierPath(ovalIn: CGRect(x: k.x - 7, y: k.y - 7, width: 14, height: 14)).fill()

            // Scrolling: the band where it stops, and a line out to the hand when it's scrolling.
            if let anchor = status.scrollAnchor {
                let a = map(anchor)
                let half = status.scrollDeadZone * video.height
                let band = NSBezierPath(roundedRect: CGRect(x: a.x - 34, y: a.y - half, width: 68, height: half * 2),
                                        xRadius: 6, yRadius: 6)
                NSColor.systemPurple.withAlphaComponent(0.25).setFill()
                band.fill()
                if status.scrollDirection != 0 {
                    let line = NSBezierPath()
                    line.move(to: a)
                    line.line(to: CGPoint(x: a.x, y: k.y))
                    line.lineWidth = 4
                    line.lineCapStyle = .round
                    NSColor.systemPurple.setStroke()
                    line.stroke()
                }
            }
        }

        drawLabel(in: video)
    }

    private var modeColor: NSColor {
        switch status.mode {
        case .none: return .systemGray
        case .point: return .systemBlue
        case .open: return .systemYellow
        case .drag: return .systemGreen
        case .scroll: return .systemPurple
        }
    }

    private func drawLabel(in video: CGRect) {
        let text: String
        if !enabled {
            text = "Paused · ⌃⌥H to turn back on"
        } else if pose == nil {
            text = "Raise your hand into view"
        } else {
            let up = status.straight.filter { $0 }.count
            var mode = status.pinched ? "Pinch · click" : status.mode.rawValue
            if status.mode == .scroll {
                mode = status.scrollDirection == 0 ? "Scroll · move up or down" : "Scrolling"
            }
            text = "\(mode) · \(up) finger\(up == 1 ? "" : "s") up · pinch gap \(String(format: "%.2f", status.pinchGap))"
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let box = CGRect(x: video.minX + 10, y: video.minY + 10, width: size.width + 16, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6).fill()
        string.draw(at: CGPoint(x: box.minX + 8, y: box.minY + 4))
    }
}
