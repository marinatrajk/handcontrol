import AVFoundation
import QuartzCore
import Vision

/// Reads the camera and finds one hand per frame with Apple's Vision framework. Nothing leaves the Mac.
final class HandTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    /// Camera frames, hand detection and the gesture engine all run on this queue.
    let queue = DispatchQueue(label: "handcontrol.tracker", qos: .userInteractive)
    /// Called on `queue` for every frame, with nil when no hand is visible.
    var onFrame: ((HandPose?, Double) -> Void)?
    /// Called on the main thread if the camera can't start.
    var onError: ((String) -> Void)?

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        return request
    }()
    private var configured = false

    func start() {
        queue.async {
            do {
                if !self.configured {
                    try self.configure()
                    self.configured = true
                }
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                let message = (error as? TrackerError)?.message ?? error.localizedDescription
                DispatchQueue.main.async { self.onError?(message) }
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() throws {
        // Prefer the built-in camera over an iPhone used as a Continuity Camera.
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices.first
        guard let device = builtIn ?? AVCaptureDevice.default(for: .video) else {
            throw TrackerError(message: "No camera found")
        }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
        guard session.canAddInput(input) else { throw TrackerError(message: "The camera is busy") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw TrackerError(message: "Can't read camera frames") }
        session.addOutput(output)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let aspect = CGFloat(CVPixelBufferGetWidth(pixels)) / CGFloat(CVPixelBufferGetHeight(pixels))
        let handler = VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up, options: [:])
        var pose: HandPose?
        if (try? handler.perform([request])) != nil, let hand = request.results?.first, hand.confidence > 0.3 {
            pose = Self.pose(from: hand, aspect: aspect)
        }
        onFrame?(pose, CACurrentMediaTime())
    }

    private static let joints: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]

    private static func pose(from hand: VNHumanHandPoseObservation, aspect: CGFloat) -> HandPose? {
        guard let found = try? hand.recognizedPoints(.all) else { return nil }
        var points: [CGPoint] = []
        var weak = 0
        for name in joints {
            guard let p = found[name] else { return nil }
            if p.confidence < 0.3 { weak += 1 }
            // Vision's origin is bottom-left of the unmirrored picture; flip to a mirror view with a top-left origin.
            points.append(CGPoint(x: 1 - p.location.x, y: 1 - p.location.y))
        }
        return weak > 6 ? nil : HandPose(points: points, aspect: aspect)
    }
}

struct TrackerError: Error {
    let message: String
}
