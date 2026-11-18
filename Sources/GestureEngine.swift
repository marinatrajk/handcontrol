import CoreGraphics
import Foundation

/// What the engine wants done. Points are in screen points with the origin at the top-left of the screen.
enum HandAction: Equatable {
    case move(CGPoint)
    case click(CGPoint)
    case dragBegin(CGPoint)
    case dragEnd(CGPoint)
    /// Scroll by this many pixels. Positive moves the content down (shows what's above), like a mouse wheel turned up.
    case scroll(Int)
    case closeWindow
}

enum HandMode: String {
    case none = "No hand"
    case point = "Pointing"
    case open = "Open hand · pointer parked"
    case drag = "Grabbing"
    case scrollReady = "Two fingers · turn them sideways to scroll"
    case scroll = "Scrolling"

    /// Modes where the pointer stays put instead of following the hand.
    var parksPointer: Bool { self == .open || self == .scrollReady || self == .scroll }
}

struct EngineStatus {
    var mode: HandMode = .none
    var straight: [Bool] = [false, false, false, false]
    var pinched = false
    var pinchGap: CGFloat = 1
    /// Where the knuckles were when scrolling started, and the band of heights where scrolling stops
    /// (picture coordinates).
    var scrollAnchor: CGPoint?
    var scrollZone: ClosedRange<CGFloat>?
    /// -1 scrolling toward the top, 1 toward the bottom, 0 not scrolling.
    var scrollDirection = 0
    /// Which way two raised fingers point, in degrees: 0 straight up, 90 sideways.
    var tilt: CGFloat?
}

/// How much the pointer is smoothed. Steadier means less wobble but a little more lag.
///
/// Measured on synthetic hands with tracking jitter and drift (./build.sh test prints these):
/// - Responsive: wobble about 4.5 pt, settles instantly (the original feel)
/// - Balanced:   wobble about 1.4 pt, settles in about 0.1 s
/// - Steady:     wobble about 0.7 pt, settles in about 0.5 s
enum Steadiness: String, CaseIterable {
    case responsive = "Responsive"
    case balanced = "Balanced"
    case steady = "Steady"

    var minCutoff: Double {
        switch self {
        case .responsive: return 1.2
        case .balanced: return 0.3
        case .steady: return 0.15
        }
    }
    /// How quickly the filter decides the hand is really moving. Lower ignores tracking drift better.
    var slopeCutoff: Double {
        switch self {
        case .responsive: return 1.0
        case .balanced: return 0.25
        case .steady: return 0.25
        }
    }
    var beta: Double {
        switch self {
        case .responsive: return 0.008
        case .balanced: return 0.008
        case .steady: return 0.006
        }
    }
    /// The pointer ignores movements smaller than this many points.
    var deadband: CGFloat {
        switch self {
        case .responsive: return 0
        case .balanced: return 5
        case .steady: return 8
        }
    }
}

/// Every tunable number in one place.
struct GestureConfig {
    /// Size of the screen being controlled, in points.
    var screen = CGSize(width: 1440, height: 900)
    /// The part of the camera picture (mirrored, 0...1, top-left origin) that maps onto the whole screen.
    /// Smaller means less arm movement but a shakier pointer.
    var region = CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.53)

    /// Finger straightness thresholds, with a gap between them so a borderline finger doesn't flicker.
    var straightOn: CGFloat = 1.18
    var straightOff: CGFloat = 1.02
    /// Thumb-to-index gap, in palm lengths, that starts and ends a pinch.
    var pinchOn: CGFloat = 0.22
    var pinchOff: CGFloat = 0.38
    /// Ignore "pinches" when the index tip is curled into the palm (a fist), in palm lengths.
    var fistReach: CGFloat = 0.35

    /// A ring or little finger scoring below this counts as folded for two-finger scroll, even if it was
    /// straight a moment ago. Those fingers are often half hidden under the thumb.
    var relaxedFold: CGFloat = 1.1

    /// A new hand shape has to win most of the frames over this long before the mode changes,
    /// so one misread frame can't block or trigger a change.
    var poseHold = 0.12
    /// Two fingers up has to last a bit longer, so a relaxed hand doesn't park the pointer by accident.
    var scrollHold = 0.2
    /// Two raised fingers count as sideways (scrolling) past `sidewaysOn` degrees from straight up, and
    /// stop counting below `sidewaysOff`. Past `sidewaysMax` they point down, which doesn't count.
    var sidewaysOn: CGFloat = 60
    var sidewaysOff: CGFloat = 45
    var sidewaysMax: CGFloat = 145
    /// Share of frames in the hold window that must show the new shape.
    var shapeAgreement = 0.7
    /// The hand can vanish this long (motion blur, a missed frame) before it counts as gone.
    var lostAfter = 0.25

    /// Click where the pointer was this long before the pinch closed, before the pinch itself nudged it.
    var clickLookback = 0.08
    /// After a click the pointer holds still this long, or until the hand moves this many points,
    /// so a double pinch lands on the same spot.
    var clickLock = 0.45
    var clickDeadZone: CGFloat = 30
    /// When the pointer starts following again, it glides there over this many seconds instead of jumping.
    var glide = 0.15

    /// Two-finger scroll works like a joystick: move your hand up or down from where you started,
    /// and the further you go the faster it scrolls. Pull back a little to stop.
    /// Distances are fractions of the picture height.
    var scrollDeadZone: CGFloat = 0.04
    var scrollRange: CGFloat = 0.2
    var scrollMaxSpeed: CGFloat = 2000   // points per second at full range
    var scrollCurve: CGFloat = 1.4
    /// Moving back toward the start by this much stops scrolling, wherever your hand is.
    var scrollBackoff: CGFloat = 0.025
    /// How much the hand position is smoothed for scrolling (0...1, lower is smoother).
    var scrollSmoothing: CGFloat = 0.35
    /// Turning your fingers sideways moves your hand too, so the start spot is only set once the
    /// hand has settled: moving slower than this (picture heights per second), or after `scrollSettleMax`.
    var scrollSettleSpeed: CGFloat = 0.15
    var scrollSettleMax = 0.8
    /// Until the first scroll, the start spot slowly re-centers on where the hand rests (this time
    /// constant, in seconds), so drift after the turn can't leave one direction easier than the other.
    var scrollRecenter = 0.6
    /// Follow the Mac's natural scrolling setting: with it on, the page moves the same way as your hand.
    var naturalScroll = true

    /// Open-hand swipe down: how far (fraction of picture height), within how long, and how straight down.
    var swipeDistance: CGFloat = 0.15
    var swipeWindow = 0.4
    var swipeMaxDrift: CGFloat = 0.7
    /// After the swipe the hand has to slow down while still in view, so dropping your hand out of
    /// the frame doesn't close anything.
    var swipeConfirm = 0.1
    var swipeGiveUp = 0.6
    var swipeSettledSpeed: CGFloat = 0.5
    var swipeBottom: CGFloat = 0.92
    var closeCooldown = 1.5

    /// Pointer smoothing: a One Euro filter (lower minCutoff is steadier when still, higher beta lags less
    /// when moving fast), then a small dead band that swallows leftover wobble.
    var minCutoff = Steadiness.balanced.minCutoff
    var beta = Steadiness.balanced.beta
    var deadband = Steadiness.balanced.deadband
    var slopeCutoff = Steadiness.balanced.slopeCutoff

    mutating func apply(_ steadiness: Steadiness) {
        minCutoff = steadiness.minCutoff
        beta = steadiness.beta
        deadband = steadiness.deadband
        slopeCutoff = steadiness.slopeCutoff
    }
}

/// Turns a stream of hand poses into pointer actions. Pure logic with no camera or system calls, so it can be tested.
///
/// - Any relaxed or pointing hand: the pointer follows your knuckles.
/// - Pinch thumb and index: click (pinch twice quickly to double-click).
/// - Two fingers up (index, middle): the pointer parks. Turn them sideways to scroll: move up or down from
///   where you started, further is faster, pull back a little to stop.
/// - Three fingers up (index, middle, ring): grab. The button stays down while you move; change shape to drop.
/// - Flat open hand (four fingers straight): the pointer parks. Swipe it down to close the front window.
final class GestureEngine {
    var config: GestureConfig

    private(set) var mode: HandMode = .none
    private(set) var straight = [false, false, false, false]
    private(set) var pinched = false
    private(set) var pinchGap: CGFloat = 1
    /// The last pointer position this engine produced.
    private(set) var cursor: CGPoint?

    var status: EngineStatus {
        EngineStatus(mode: mode, straight: straight, pinched: pinched, pinchGap: pinchGap,
                     scrollAnchor: mode == .scroll ? scrollAnchor : nil,
                     scrollZone: mode == .scroll ? scrollLo...scrollHi : nil,
                     scrollDirection: scrollDirection, tilt: tilt)
    }

    private enum Shape { case point, two, twoSideways, three, open }
    private var shape = Shape.point
    private var shapes: [(t: Double, s: Shape)] = []
    private var present = false
    private var lastSeen = -Double.infinity
    private var lastFrame = 0.0
    private var pointer = CGPoint.zero

    private var fx = OneEuro()
    private var fy = OneEuro()
    private var held: CGPoint?
    private var trail: [(t: Double, p: CGPoint)] = []
    private var lock: (p: CGPoint, until: Double)?
    private var glideFrom: (p: CGPoint, t: Double)?

    /// The knuckles, lightly smoothed, for scrolling. (Recorded hands showed people turn their fingers
    /// sideways around the knuckles, while the wrist swings a long way.)
    private var palm: CGPoint?
    private var scrollSettled = false
    private var scrollStarted = false
    private var scrollEntered = 0.0
    private var sideways = false
    private var tilt: CGFloat?
    private var scrollAnchor: CGPoint?
    /// Scrolling stops while the hand is between these heights (picture coordinates).
    private var scrollLo: CGFloat = 0
    private var scrollHi: CGFloat = 0
    private var scrollPeak: CGFloat?
    private var scrollCarry: CGFloat = 0
    private var scrollDirection = 0

    private var swipe: [(t: Double, p: CGPoint)] = []
    private var recent: [(t: Double, p: CGPoint)] = []
    private var notOpenSince: Double?
    private var pendingClose: Double?
    private var lastClose = -Double.infinity

    init(config: GestureConfig = GestureConfig()) {
        self.config = config
    }

    /// Feed one camera frame. `hand` is nil when no hand was found; `pointer` is where the real pointer is now.
    func update(_ hand: HandPose?, at t: Double, pointer: CGPoint) -> [HandAction] {
        self.pointer = pointer
        guard let hand else {
            return present && t - lastSeen > config.lostAfter ? reset() : []
        }
        lastSeen = t
        var out: [HandAction] = []

        // Which fingers are straight.
        for finger in Finger.allCases {
            let s = hand.straightness(finger), i = finger.rawValue
            if straight[i] {
                if s < config.straightOff { straight[i] = false }
            } else if s > config.straightOn {
                straight[i] = true
            }
        }

        // Pinch.
        pinchGap = hand.pinchGap
        let wasPinched = pinched
        if pinched {
            if pinchGap > config.pinchOff { pinched = false }
        } else if pinchGap < config.pinchOn && hand.indexReach > config.fistReach {
            pinched = true
        }

        // Hand shape. A hand on its way into a pinch is always "pointing".
        // Ring and little fingers count as folded when they're only half straight, since they're
        // often tucked under the thumb and hard for the camera to see.
        let ringDown = !straight[2] || hand.straightness(.ring) < config.relaxedFold
        let littleDown = !straight[3] || hand.straightness(.little) < config.relaxedFold
        let raw: Shape
        if pinchGap < config.pinchOff {
            raw = .point
        } else if straight.allSatisfy({ $0 }) && !ringDown && !littleDown {
            raw = .open
        } else if straight[0] && straight[1] && ringDown && littleDown {
            let angle = hand.twoFingerTilt
            if sideways {
                if angle < config.sidewaysOff || angle > config.sidewaysMax + 10 { sideways = false }
            } else if angle > config.sidewaysOn && angle < config.sidewaysMax {
                sideways = true
            }
            tilt = angle
            raw = sideways ? .twoSideways : .two
        } else if straight[0] && straight[1] && straight[2] {
            raw = .three
        } else {
            raw = .point
        }
        if raw != .two && raw != .twoSideways {
            sideways = false
            tilt = nil
        }

        // A new shape has to win most frames over a short window before it counts.
        let dt = present ? min(max(t - lastFrame, 0), 0.1) : 0
        lastFrame = t
        if !present {
            present = true
            fx.reset(); fy.reset()
            held = nil; palm = nil
            trail = []; swipe = []; recent = []; notOpenSince = nil; pendingClose = nil
            shapes = []
            // Don't grab or scroll the instant a hand appears.
            shape = raw == .three || raw == .two || raw == .twoSideways ? .point : raw
        }
        shapes.append((t, raw))
        shapes.removeAll { t - $0.t > 0.5 }
        if raw != shape {
            // Raising two fingers waits a little longer; turning them back up from scrolling is quick.
            let hold = raw == .two && shape != .twoSideways ? config.scrollHold : config.poseHold
            if let oldest = shapes.first, t - oldest.t >= hold - 0.001 {
                let window = shapes.filter { t - $0.t <= hold + 0.001 }
                let agree = window.filter { $0.s == raw }.count
                if Double(agree) >= Double(window.count) * config.shapeAgreement { shape = raw }
            }
        }

        // Where the hand points on screen: smoothed, then held still through tiny wobbles.
        let target = toScreen(hand.knuckles)
        let smooth = CGPoint(x: fx.filter(target.x, t, minCutoff: config.minCutoff, beta: config.beta, slopeCutoff: config.slopeCutoff),
                             y: fy.filter(target.y, t, minCutoff: config.minCutoff, beta: config.beta, slopeCutoff: config.slopeCutoff))
        let aim = deadband(smooth)
        let k = hand.knuckles
        let a = config.scrollSmoothing
        palm = palm.map { CGPoint(x: $0.x + (k.x - $0.x) * a, y: $0.y + (k.y - $0.y) * a) } ?? k

        // Mode changes.
        let newMode: HandMode
        switch shape {
        case .open: newMode = .open
        case .three: newMode = .drag
        case .two: newMode = .scrollReady
        case .twoSideways: newMode = .scroll
        case .point: newMode = .point
        }
        if newMode != mode {
            if mode == .drag { out.append(.dragEnd(cursor ?? pointer)) }
            if !newMode.parksPointer && (mode.parksPointer || mode == .none) {
                glideFrom = (pointer, t)
                cursor = pointer
            }
            mode = newMode
            if mode == .drag { out.append(.dragBegin(cursor ?? pointer)) }
            if mode == .scroll, let palm {
                scrollAnchor = palm
                scrollLo = palm.y - config.scrollDeadZone
                scrollHi = palm.y + config.scrollDeadZone
                scrollPeak = nil
                scrollCarry = 0
                scrollSettled = false
                scrollStarted = false
                scrollEntered = t
            }
            scrollDirection = 0
        }

        // Click the moment a pinch closes.
        if pinched && !wasPinched && mode != .drag {
            var p = cursor ?? pointer
            if mode.parksPointer {
                p = pointer
            } else if lock == nil, glideFrom == nil, let past = trail.last(where: { $0.t <= t - config.clickLookback }) {
                p = past.p
            }
            out.append(.click(p))
            cursor = p
            lock = (p, t + config.clickLock)
        }

        // Follow the hand while pointing or grabbing.
        if mode == .point || mode == .drag {
            var p = aim
            if let l = lock {
                if t < l.until && distance(aim, l.p) < config.clickDeadZone {
                    p = l.p
                } else {
                    lock = nil
                    glideFrom = (cursor ?? l.p, t)
                }
            }
            if lock == nil, let g = glideFrom {
                let k = min(1, (t - g.t) / config.glide)
                let e = CGFloat(k * k * (3 - 2 * k))
                p = CGPoint(x: g.p.x + (aim.x - g.p.x) * e, y: g.p.y + (aim.y - g.p.y) * e)
                if k >= 1 { glideFrom = nil }
            }
            if cursor.map({ distance($0, p) >= 0.5 }) ?? true {
                out.append(.move(p))
                cursor = p
            }
        } else {
            cursor = pointer
        }
        trail.append((t, cursor ?? pointer))
        trail.removeAll { t - $0.t > 0.5 }

        // Two fingers: scroll faster the further the hand is past the stop zone around the start.
        // Pulling back a little stops it right there, and the stop zone follows the hand back toward
        // the start, so returning your hand never scrolls the other way.
        if mode == .scroll, !scrollSettled, let palm {
            // Still finishing the turn: keep moving the start spot with the hand until it holds still.
            scrollAnchor = palm
            scrollLo = palm.y - config.scrollDeadZone
            scrollHi = palm.y + config.scrollDeadZone
            scrollPeak = nil
            scrollCarry = 0
            let fingersSideways = (tilt ?? 0) >= config.sidewaysOn
            let caughtUp = abs(palm.y - k.y) < config.scrollDeadZone / 4
            if (fingersSideways && caughtUp && speed() < config.scrollSettleSpeed) || t - scrollEntered > config.scrollSettleMax {
                scrollSettled = true
            }
        } else if mode == .scroll, var anchor = scrollAnchor, let palm {
            let dz = config.scrollDeadZone, y = palm.y
            if !scrollStarted && y > anchor.y - dz && y < anchor.y + dz && speed() < config.scrollSettleSpeed {
                // Not scrolled yet and resting (or barely drifting) inside the stop zone: ease the start
                // spot over to the hand. A deliberate move is too fast for this to chase.
                anchor.y += (y - anchor.y) * CGFloat(min(1, dt / config.scrollRecenter))
                scrollAnchor = anchor
                scrollLo = anchor.y - dz
                scrollHi = anchor.y + dz
            }
            scrollLo = min(anchor.y - dz, max(scrollLo, y - dz))
            scrollHi = max(anchor.y + dz, min(scrollHi, y + dz))
            var over: CGFloat = 0
            if y > scrollHi {
                let peak = max(scrollPeak ?? y, y)
                if y < peak - config.scrollBackoff {
                    scrollHi = y + dz / 2
                    scrollPeak = nil
                } else {
                    scrollPeak = peak
                    over = y - scrollHi
                }
            } else if y < scrollLo {
                let peak = min(scrollPeak ?? y, y)
                if y > peak + config.scrollBackoff {
                    scrollLo = y - dz / 2
                    scrollPeak = nil
                } else {
                    scrollPeak = peak
                    over = y - scrollLo
                }
            } else {
                scrollPeak = nil
            }
            // Only scroll on frames where the fingers really are sideways, so starting to turn them
            // back up stops it at once.
            if over != 0 && raw == .twoSideways && (tilt ?? 0) >= config.sidewaysOn {
                let k = min(1, abs(over) / config.scrollRange)
                let speed = config.scrollMaxSpeed * pow(k, config.scrollCurve)
                // Hand down: natural scrolling moves the content down too (positive), like a trackpad.
                let sign: CGFloat = (over > 0 ? 1 : -1) * (config.naturalScroll ? 1 : -1)
                scrollCarry += sign * speed * CGFloat(dt)
                let whole = scrollCarry.rounded(.towardZero)
                if whole != 0 {
                    out.append(.scroll(Int(whole)))
                    scrollCarry -= whole
                    scrollStarted = true
                }
                scrollDirection = over > 0 ? 1 : -1
            } else {
                scrollCarry = 0
                scrollDirection = 0
            }
        }

        // Open hand swiped down: close the front window.
        recent.append((t, hand.knuckles))
        recent.removeAll { t - $0.t > 0.3 }
        if raw == .open {
            swipe.append((t, hand.knuckles))
            notOpenSince = nil
        } else if notOpenSince == nil {
            notOpenSince = t
        }
        if let since = notOpenSince, t - since > 0.1 {
            swipe = []
        }
        swipe.removeAll { t - $0.t > config.swipeWindow }

        if pendingClose == nil, mode == .open, t - lastClose > config.closeCooldown,
           let top = swipe.min(by: { $0.p.y < $1.p.y }), let last = swipe.last, last.t > top.t {
            let dy = last.p.y - top.p.y
            let dx = abs(last.p.x - top.p.x) * hand.aspect
            if dy >= config.swipeDistance && dx <= dy * config.swipeMaxDrift {
                pendingClose = t
            }
        }
        if let armed = pendingClose {
            if t - armed > config.swipeGiveUp {
                pendingClose = nil
                swipe = []
            } else if t - armed >= config.swipeConfirm, (raw == .open || mode == .open),
                      hand.knuckles.y < config.swipeBottom, speed() < config.swipeSettledSpeed {
                pendingClose = nil
                swipe = []
                lastClose = t
                out.append(.closeWindow)
            }
        }
        return out
    }

    /// Forget the hand (it left the frame, or control was turned off). Releases a grab if one is held.
    @discardableResult
    func reset() -> [HandAction] {
        var out: [HandAction] = []
        if mode == .drag { out.append(.dragEnd(cursor ?? pointer)) }
        present = false
        mode = .none
        pinched = false
        straight = [false, false, false, false]
        cursor = nil
        held = nil
        lock = nil
        glideFrom = nil
        palm = nil
        sideways = false
        tilt = nil
        scrollAnchor = nil
        scrollDirection = 0
        swipe = []
        recent = []
        pendingClose = nil
        trail = []
        return out
    }

    private func toScreen(_ p: CGPoint) -> CGPoint {
        let r = config.region
        let nx = min(max((p.x - r.minX) / r.width, 0), 1)
        let ny = min(max((p.y - r.minY) / r.height, 0), 1)
        return CGPoint(x: nx * (config.screen.width - 1), y: ny * (config.screen.height - 1))
    }

    /// Holds the pointer still until the smoothed position moves more than `deadband` points away,
    /// then trails it by that much. Removes the last bit of wobble when your hand is still.
    private func deadband(_ p: CGPoint) -> CGPoint {
        guard config.deadband > 0, let h = held else {
            held = p
            return p
        }
        let d = distance(p, h)
        guard d > config.deadband else { return h }
        let k = (d - config.deadband) / d
        let next = CGPoint(x: h.x + (p.x - h.x) * k, y: h.y + (p.y - h.y) * k)
        held = next
        return next
    }

    /// How fast the knuckles moved over the last ~0.1 s, in picture heights per second.
    private func speed() -> CGFloat {
        guard let last = recent.last, let earlier = recent.last(where: { last.t - $0.t >= 0.09 }) else { return .infinity }
        return abs(last.p.y - earlier.p.y) / CGFloat(last.t - earlier.t)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}

/// The One Euro filter: smooths heavily when the hand is still and barely at all when it moves fast.
struct OneEuro {
    private var value: Double?
    private var slope = 0.0
    private var time = 0.0

    mutating func reset() { value = nil; slope = 0 }

    mutating func filter(_ x: Double, _ t: Double, minCutoff: Double, beta: Double, slopeCutoff: Double = 1.0) -> Double {
        guard let prev = value else {
            value = x; time = t; slope = 0
            return x
        }
        let dt = max(t - time, 1e-3)
        time = t
        slope += alpha(slopeCutoff, dt) * ((x - prev) / dt - slope)
        let next = prev + alpha(minCutoff + beta * abs(slope), dt) * (x - prev)
        value = next
        return next
    }

    private func alpha(_ cutoff: Double, _ dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}
