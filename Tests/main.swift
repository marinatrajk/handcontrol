import CoreGraphics
import Foundation

// Drives the gesture engine with synthetic hands at 30 frames per second and checks what it does.

// MARK: - Synthetic hands

enum FingerShape { case straight, curled, pinching }
enum ThumbShape { case out, tucked, onIndexTip, wrapped }

var seed: UInt64 = 42
func noise() -> CGFloat {
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return CGFloat(Double(seed >> 11) / Double(1 << 53)) * 2 - 1
}

/// A right hand, palm to the camera, fingers up, with its knuckle center at `c`.
/// Offsets are in palm lengths (`s`, in picture heights).
func hand(at c: CGPoint, _ fingers: [FingerShape], thumb: ThumbShape = .tucked,
          size s: CGFloat = 0.18, jitter: CGFloat = 0.0015) -> HandPose {
    let aspect: CGFloat = 16.0 / 9.0
    var points = [CGPoint](repeating: .zero, count: 21)
    func put(_ j: Joint, _ u: CGFloat, _ v: CGFloat) {
        points[j.rawValue] = CGPoint(x: c.x + u * s / aspect + noise() * jitter, y: c.y + v * s + noise() * jitter)
    }
    put(.wrist, 0, 1)
    let across: [CGFloat] = [-0.3, -0.1, 0.1, 0.3]
    for f in Finger.allCases {
        let u = across[f.rawValue], len: CGFloat = f == .little ? 0.8 : 1
        put(f.mcp, u, 0)
        switch fingers[f.rawValue] {
        case .straight:
            put(f.pip, u, -0.45 * len); put(f.dip, u, -0.7 * len); put(f.tip, u, -0.9 * len)
        case .curled:
            put(f.pip, u, -0.25 * len); put(f.dip, u, -0.1 * len); put(f.tip, u, 0.2 * len)
        case .pinching:
            put(f.pip, u - 0.1, -0.4); put(f.dip, u - 0.2, -0.45); put(f.tip, u - 0.3, -0.42)
        }
    }
    put(.thumbCMC, -0.35, 0.75); put(.thumbMP, -0.55, 0.45); put(.thumbIP, -0.7, 0.2)
    switch thumb {
    case .out: put(.thumbTip, -0.8, 0)
    case .tucked: put(.thumbTip, 0.1, 0.1)
    case .wrapped: put(.thumbTip, -0.25, 0.1)
    case .onIndexTip:
        let tip = points[Joint.indexTip.rawValue]
        points[Joint.thumbTip.rawValue] = CGPoint(x: tip.x + 0.03 * s / aspect, y: tip.y + 0.03 * s)
    }
    return HandPose(points: points, aspect: aspect)
}

let pointing: [FingerShape] = [.straight, .curled, .curled, .curled]
let pinch: [FingerShape] = [.pinching, .curled, .curled, .curled]
let okSign: [FingerShape] = [.pinching, .straight, .straight, .straight]
let three: [FingerShape] = [.straight, .straight, .straight, .curled]
let open: [FingerShape] = [.straight, .straight, .straight, .straight]
let fist: [FingerShape] = [.curled, .curled, .curled, .curled]
let center = CGPoint(x: 0.5, y: 0.515)   // middle of the default region

// MARK: - Harness

final class Sim {
    let engine: GestureEngine
    var t = 100.0
    var pointer = CGPoint(x: 200, y: 200)

    init() {
        var config = GestureConfig()
        config.screen = CGSize(width: 1000, height: 1000)
        engine = GestureEngine(config: config)
    }

    /// Runs `seconds` of frames; `frame` gets progress 0...1 and returns the hand (or nil).
    @discardableResult
    func run(_ seconds: Double, _ frame: (CGFloat) -> HandPose?) -> [HandAction] {
        let n = max(1, Int((seconds * 30).rounded()))
        var actions: [HandAction] = []
        for i in 0..<n {
            let k = n > 1 ? CGFloat(i) / CGFloat(n - 1) : 1
            let out = engine.update(frame(k), at: t, pointer: pointer)
            for a in out { if let p = a.point { pointer = p } }   // the real pointer goes where events send it
            actions += out
            t += 1.0 / 30
        }
        return actions
    }
}

extension HandAction {
    var point: CGPoint? {
        switch self {
        case .move(let p), .click(let p), .dragBegin(let p), .dragEnd(let p): return p
        case .closeWindow: return nil
        }
    }
    var isMove: Bool { if case .move = self { return true }; return false }
    var isClick: Bool { if case .click = self { return true }; return false }
    var isDragBegin: Bool { if case .dragBegin = self { return true }; return false }
    var isDragEnd: Bool { if case .dragEnd = self { return true }; return false }
}

var failures = 0
func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
    let extra = detail()
    print(ok ? "  ✅" : "  ❌", name, extra.isEmpty ? "" : "(\(extra))")
    if !ok { failures += 1 }
}
func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
func lerp(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k) }
func at(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: center.x + dx, y: center.y + dy) }

// MARK: - Scenarios

print("Pointer")
do {
    let sim = Sim()
    let acts = sim.run(1.0) { _ in hand(at: center, pointing) }
    check(acts.contains { $0.isMove }, "a pointing hand moves the pointer")
    check(dist(sim.pointer, CGPoint(x: 500, y: 500)) < 6, "hand in the middle of the area puts the pointer mid-screen", "\(sim.pointer)")
    var spots: [CGPoint] = []
    sim.run(1.0) { _ in spots.append(sim.pointer); return hand(at: center, pointing, jitter: 0.003) }
    let spread = spots.map { dist($0, spots[0]) }.max() ?? 0
    check(spread < 6, "a still but shaky hand keeps the pointer steady", "wobble \(Int(spread)) pt")
    sim.run(0.5) { k in hand(at: at(0.15 * k, 0), pointing) }
    sim.run(0.3) { _ in hand(at: at(0.15, 0), pointing) }
    check(sim.pointer.x > 720, "moving the hand right moves the pointer right", "x = \(Int(sim.pointer.x))")
    let acts2 = sim.run(0.6) { k in hand(at: at(0.15, 0.25 * k), pointing) }
    check(!acts2.contains(.closeWindow), "moving a pointing hand down fast doesn't close a window")
    let lost = sim.run(0.5) { _ in nil }
    check(lost.isEmpty && sim.engine.mode == .none, "hand leaving the frame stops control quietly")
}

print("Click")
do {
    let sim = Sim()
    sim.run(1.0) { _ in hand(at: center, pointing) }
    let before = sim.pointer
    var acts = sim.run(0.15) { _ in hand(at: center, pinch, thumb: .onIndexTip) }
    acts += sim.run(0.4) { _ in hand(at: center, pinch, thumb: .onIndexTip) }
    check(acts.filter { $0.isClick }.count == 1, "one pinch = one click, even when held")
    if let c = acts.first(where: { $0.isClick })?.point {
        check(dist(c, before) < 15, "the click lands where the pointer was", "\(Int(dist(c, before))) pt away")
    }
    sim.run(0.15) { _ in hand(at: center, pointing) }
    let second = sim.run(0.2) { _ in hand(at: center, pinch, thumb: .onIndexTip) }
    let clicks = (acts + second).filter { $0.isClick }.compactMap { $0.point }
    check(clicks.count == 2, "pinch twice quickly = two clicks (a double-click)")
    if clicks.count == 2 { check(dist(clicks[0], clicks[1]) < 1, "both clicks hit the same spot") }
    sim.run(1.0) { _ in hand(at: center, pointing) }
    let fists = sim.run(0.6) { _ in hand(at: center, fist, thumb: .wrapped) }
                + sim.run(0.6) { _ in hand(at: center, fist, thumb: .out) }
    check(!fists.contains { $0.isClick }, "making a fist doesn't click")
    let ok = sim.run(0.5) { _ in hand(at: center, okSign, thumb: .onIndexTip) }
    check(ok.filter { $0.isClick }.count == 1, "an OK-sign pinch (other fingers up) clicks too")
}

print("Grab")
do {
    let sim = Sim()
    sim.run(1.0) { _ in hand(at: center, pointing) }
    var acts = sim.run(0.4) { _ in hand(at: center, three) }
    check(acts.filter { $0.isDragBegin }.count == 1, "three fingers up grabs (mouse button down)")
    acts = sim.run(0.5) { k in hand(at: at(-0.12 * k, -0.1 * k), three) }
    check(acts.contains { $0.isMove } && !acts.contains { $0.isDragEnd }, "moving while grabbing drags")
    acts = sim.run(0.4) { _ in hand(at: at(-0.12, -0.1), open) }
    check(acts.filter { $0.isDragEnd }.count == 1, "opening the hand drops it (mouse button up)")
    check(!acts.contains { $0.isClick }, "grab and drop don't also click")
    sim.run(0.5) { _ in hand(at: center, pointing) }
    sim.run(0.4) { _ in hand(at: center, three) }
    let gone = sim.run(0.5) { _ in nil }
    check(gone.filter { $0.isDragEnd }.count == 1, "hand leaving mid-grab drops it")
    let instant = Sim()
    let first = instant.run(0.05) { _ in hand(at: center, three) }
    check(!first.contains { $0.isDragBegin }, "a hand that appears already showing three fingers doesn't grab instantly")
}

print("Open hand and close window")
do {
    let sim = Sim()
    sim.run(1.0) { _ in hand(at: center, pointing) }
    sim.run(0.3) { _ in hand(at: center, open) }
    let parked = sim.pointer
    var acts = sim.run(0.5) { k in hand(at: at(0.1 * k, -0.1 * k), open) }
    check(!acts.contains { $0.isMove }, "an open hand parks the pointer")
    check(sim.pointer == parked, "the pointer stays where it was")
    sim.run(0.3) { _ in hand(at: at(0.1, -0.15), open) }
    acts = sim.run(0.2) { k in hand(at: at(0.1, -0.15 + 0.22 * k), open) }
    acts += sim.run(0.4) { _ in hand(at: at(0.1, 0.07), open) }
    check(acts.filter { $0 == .closeWindow }.count == 1, "open hand swiped down closes one window")

    sim.run(2.0) { _ in hand(at: at(0, -0.15), open) }
    acts = sim.run(0.5) { k in hand(at: at(0, -0.15 + 0.4 * k), open) }
    acts += sim.run(0.5) { _ in nil }
    check(!acts.contains(.closeWindow), "dropping an open hand out of view doesn't close anything")

    sim.run(2.0) { _ in hand(at: at(0, -0.15), open) }
    acts = sim.run(1.5) { k in hand(at: at(0, -0.15 + 0.22 * k), open) }
    acts += sim.run(0.4) { _ in hand(at: at(0, 0.07), open) }
    check(!acts.contains(.closeWindow), "slowly lowering an open hand doesn't close anything")

    sim.run(2.0) { _ in hand(at: at(0, -0.15), open) }
    acts = sim.run(0.2) { k in hand(at: at(0, -0.15 + 0.22 * k), open) }
    acts += sim.run(0.25) { _ in hand(at: at(0, 0.07), open) }
    acts += sim.run(0.2) { k in hand(at: at(0, -0.15 + 0.22 * k), open) }
    acts += sim.run(0.4) { _ in hand(at: at(0, 0.07), open) }
    check(acts.filter { $0 == .closeWindow }.count == 1, "two quick swipes only close one window")

    let ok = Sim()
    ok.run(1.0) { _ in hand(at: center, pointing) }
    ok.run(0.5) { _ in hand(at: center, open) }
    let p = ok.pointer
    let clicked = ok.run(0.1) { _ in hand(at: at(0.02, 0), okSign, thumb: .onIndexTip) }
    check(clicked.first { $0.isClick }?.point == p, "pinching from an open hand clicks at the parked pointer")
}

print(failures == 0 ? "\nAll checks passed" : "\n\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
