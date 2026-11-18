import CoreGraphics

/// The 21 hand joints, in the same order MediaPipe and most hand-tracking code use.
enum Joint: Int, CaseIterable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// The four long fingers (the thumb is handled separately, for pinching).
enum Finger: Int, CaseIterable {
    case index, middle, ring, little

    var mcp: Joint { Joint(rawValue: 5 + rawValue * 4)! }
    var pip: Joint { Joint(rawValue: 6 + rawValue * 4)! }
    var dip: Joint { Joint(rawValue: 7 + rawValue * 4)! }
    var tip: Joint { Joint(rawValue: 8 + rawValue * 4)! }
}

/// One detected hand.
///
/// Points are normalized to the camera picture as you see yourself in a mirror:
/// x runs 0 (left) to 1 (right), y runs 0 (top) to 1 (bottom).
struct HandPose {
    /// Indexed by `Joint.rawValue`.
    var points: [CGPoint]
    /// Picture width / height, so distances are measured in true proportions.
    var aspect: CGFloat

    subscript(_ joint: Joint) -> CGPoint { points[joint.rawValue] }

    /// Distance between two joints, in picture heights.
    func distance(_ a: Joint, _ b: Joint) -> CGFloat {
        let p = self[a], q = self[b]
        return hypot((p.x - q.x) * aspect, p.y - q.y)
    }

    /// Wrist to middle knuckle. Other distances are divided by this, so gestures work near or far from the camera.
    var palmSize: CGFloat { max(distance(.wrist, .middleMCP), 1e-4) }

    /// How straight a finger is: tip-to-wrist over middle-joint-to-wrist.
    /// About 1.3 when straight, under 1.0 when curled into the palm.
    func straightness(_ finger: Finger) -> CGFloat {
        distance(.wrist, finger.tip) / max(distance(.wrist, finger.pip), 1e-4)
    }

    /// Thumb tip to index tip, in palm lengths. Under about 0.2 means pinching.
    var pinchGap: CGFloat { distance(.thumbTip, .indexTip) / palmSize }

    /// Index tip to index knuckle, in palm lengths. Small when the hand is a fist.
    var indexReach: CGFloat { distance(.indexTip, .indexMCP) / palmSize }

    /// The pointer anchor: the middle of the four knuckles.
    /// Knuckles barely move when fingers bend, so pinching doesn't nudge the pointer.
    var knuckles: CGPoint {
        let joints: [Joint] = [.indexMCP, .middleMCP, .ringMCP, .littleMCP]
        let sum = joints.reduce(CGPoint.zero) { CGPoint(x: $0.x + self[$1].x, y: $0.y + self[$1].y) }
        return CGPoint(x: sum.x / 4, y: sum.y / 4)
    }
}
