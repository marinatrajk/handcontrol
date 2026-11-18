import CoreGraphics
import Foundation

/// What the engine wants done. Points are in screen points with the origin at the top-left of the screen.
enum HandAction: Equatable {
    case move(CGPoint)
    case click(CGPoint)
    case dragBegin(CGPoint)
    case dragEnd(CGPoint)
    case closeWindow
}

enum HandMode: String {
    case none = "No hand"
    case point = "Pointing"
    case open = "Open hand · pointer parked"
    case drag = "Grabbing"
}

struct EngineStatus {
    var mode: HandMode = .none
    var straight: [Bool] = [false, false, false, false]
    var pinched = false
    var pinchGap: CGFloat = 1
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

    /// A new hand shape has to last this long before the mode changes.
    var poseHold = 0.12
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

    /// Pointer smoothing (One Euro filter): lower minCutoff is steadier when still, higher beta lags less when moving fast.
    var minCutoff = 1.2
    var beta = 0.008
}

/// Turns a stream of hand poses into pointer actions. Pure logic with no camera or system calls, so it can be tested.
///
/// - Any relaxed or pointing hand: the pointer follows your knuckles.
/// - Pinch thumb and index: click (pinch twice quickly to double-click).
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

    var status: EngineStatus { EngineStatus(mode: mode, straight: straight, pinched: pinched, pinchGap: pinchGap) }

    private enum Shape { case point, three, open }
    private var shape = Shape.point
    private var candidate = Shape.point
    private var candidateSince = 0.0
    private var present = false
    private var lastSeen = -Double.infinity
    private var pointer = CGPoint.zero

    private var fx = OneEuro()
    private var fy = OneEuro()
    private var trail: [(t: Double, p: CGPoint)] = []
    private var lock: (p: CGPoint, until: Double)?
    private var glideFrom: (p: CGPoint, t: Double)?

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

        // Hand shape. A hand on its way into a pinch is never "open" or "three".
        let raw: Shape
        if pinchGap < config.pinchOff {
            raw = .point
        } else if straight.allSatisfy({ $0 }) {
            raw = .open
        } else if straight[0] && straight[1] && straight[2] {
            raw = .three
        } else {
            raw = .point
        }

        // A new shape has to hold for a moment before it counts.
        if !present {
            present = true
            fx.reset(); fy.reset()
            trail = []; swipe = []; recent = []; notOpenSince = nil; pendingClose = nil
            shape = raw == .three ? .point : raw   // don't grab the instant a hand appears
            candidate = raw
            candidateSince = t
        } else if raw != candidate {
            candidate = raw
            candidateSince = t
        } else if raw != shape && t - candidateSince >= config.poseHold {
            shape = raw
        }

        // Where the hand points on screen, smoothed.
        let target = toScreen(hand.knuckles)
        let aim = CGPoint(x: fx.filter(target.x, t, minCutoff: config.minCutoff, beta: config.beta),
                          y: fy.filter(target.y, t, minCutoff: config.minCutoff, beta: config.beta))

        // Mode changes.
        let newMode: HandMode = shape == .open ? .open : shape == .three ? .drag : .point
        if newMode != mode {
            if mode == .drag { out.append(.dragEnd(cursor ?? pointer)) }
            if newMode != .open && (mode == .open || mode == .none) {
                glideFrom = (pointer, t)
                cursor = pointer
            }
            mode = newMode
            if mode == .drag { out.append(.dragBegin(cursor ?? pointer)) }
        }

        // Click the moment a pinch closes.
        if pinched && !wasPinched && mode != .drag {
            var p = cursor ?? pointer
            if mode == .open {
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
        lock = nil
        glideFrom = nil
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
