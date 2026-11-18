import CoreGraphics
import Foundation

/// Plays a saved hand recording through the gesture engine and prints, frame by frame,
/// how straight each finger looked, the pinch gap, the mode, and anything the engine did.
///   ./build.sh replay ~/Library/Logs/HandControl/hand-….json
func replay(_ path: String) {
    guard let data = FileManager.default.contents(atPath: path),
          let recording = try? JSONDecoder().decode(HandRecording.self, from: data) else {
        print("Can't read a hand recording at \(path)")
        return
    }
    var config = GestureConfig()
    config.screen = CGSize(width: 1512, height: 982)
    let engine = GestureEngine(config: config)
    var pointer = CGPoint(x: 756, y: 491)
    let start = recording.frames.first?.t ?? 0
    var modeTime: [String: Double] = [:]
    var last = start
    var scrolled = 0

    print("  time  straightness i/m/r/l        pinch  tilt  wrist y  mode")
    for frame in recording.frames {
        let pose = recording.pose(frame)
        let actions = engine.update(pose, at: frame.t, pointer: pointer)
        var events: [String] = []
        for action in actions {
            switch action {
            case .move(let p): pointer = p
            case .click(let p): pointer = p; events.append("CLICK")
            case .dragBegin(let p): pointer = p; events.append("GRAB")
            case .dragEnd(let p): pointer = p; events.append("DROP")
            case .scroll(let n): scrolled += n; events.append("scroll \(n)")
            case .closeWindow: events.append("CLOSE WINDOW")
            }
        }
        let status = engine.status
        modeTime[status.mode.rawValue, default: 0] += frame.t - last
        last = frame.t
        let fingers = pose.map { p in
            Finger.allCases.map { String(format: "%.2f", p.straightness($0)) }.joined(separator: " ")
        } ?? "   (no hand)       "
        let gap = pose.map { String(format: "%.2f", $0.pinchGap) } ?? "  -  "
        let flags = status.straight.map { $0 ? "|" : "." }.joined()
        let tilt = pose.map { String(format: "%4.0f°", $0.twoFingerTilt) } ?? "    -"
        let wrist = pose.map { String(format: "%.3f", $0[.wrist].y) } ?? "  -  "
        print(String(format: "%6.2f  ", frame.t - start) + "\(fingers) \(flags)  \(gap)  \(tilt)  \(wrist)  \(status.mode.rawValue)"
              + (events.isEmpty ? "" : "   → " + events.joined(separator: ", ")))
    }
    print("\nTime in each mode:")
    for (mode, time) in modeTime.sorted(by: { $0.value > $1.value }) {
        print(String(format: "  %5.1f s  %@", time, mode))
    }
    print("Scrolled \(scrolled) px in total")
}
