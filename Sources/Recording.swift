import CoreGraphics
import Foundation

/// A few seconds of tracked hand joints, saved so gestures can be tuned on a real hand.
/// It holds only the 21 joint positions per frame, never camera images.
struct HandRecording: Codable {
    struct Frame: Codable {
        var t: Double
        /// x0, y0, x1, y1, … for the 21 joints, or nil when no hand was found.
        var points: [Double]?
    }

    var aspect: Double = 16.0 / 9.0
    var frames: [Frame] = []

    mutating func add(_ pose: HandPose?, at t: Double) {
        if let pose { aspect = Double(pose.aspect) }
        frames.append(Frame(t: t, points: pose?.points.flatMap { [Double($0.x), Double($0.y)] }))
    }

    func pose(_ frame: Frame) -> HandPose? {
        guard let p = frame.points, p.count == Joint.allCases.count * 2 else { return nil }
        let points = stride(from: 0, to: p.count, by: 2).map { CGPoint(x: p[$0], y: p[$0 + 1]) }
        return HandPose(points: points, aspect: CGFloat(aspect))
    }

    /// ~/Library/Logs/HandControl
    static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/HandControl", isDirectory: true)
    }

    /// Saves to the folder above and returns the file's URL.
    func save() throws -> URL {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = Self.folder.appendingPathComponent("hand-\(stamp.string(from: Date())).json")
        try JSONEncoder().encode(self).write(to: url)
        return url
    }
}
