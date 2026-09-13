import AVFoundation
import CoreImage
import Observation

@MainActor
@Observable
final class CameraLab {
    private(set) var canvas = PixelCanvas()
    private(set) var isRunning = false
    private(set) var status = "Camera stopped"

    @ObservationIgnored private let capture = CameraCapture()
    @ObservationIgnored private let sender = ArtNetSender()

    init() {
        capture.onFrame = { [weak self] canvas in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                self.canvas = canvas
                self.status = "Streaming mirrored camera frame"
                self.sender.send(canvas)
            }
        }
        capture.onFailure = { [weak self] message in
            Task { @MainActor in
                self?.status = message
                self?.isRunning = false
            }
        }
    }

    func start(host: String?) {
        guard !isRunning else { return }
        status = "Requesting camera access…"
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            Task { @MainActor in
                guard let self else { return }
                guard allowed else {
                    self.status = "Camera access denied — enable it in System Settings"
                    return
                }
                if let host, !host.isEmpty { self.sender.connect(host: host) }
                self.isRunning = true
                self.status = "Starting camera…"
                self.capture.start()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        capture.stop()
        status = "Camera stopped"
        canvas = PixelCanvas()
        sender.send(canvas)
        sender.disconnect()
    }
}

/// Camera work stays off the main actor. Only finished 32×8 RGB canvases cross
/// back into the UI; source camera frames are never retained.
private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    var onFrame: (@Sendable (PixelCanvas) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "agentclock.camera", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var configured = false
    private var lastFrameAt: CFTimeInterval = 0

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                if !self.configured { try self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            } catch {
                self.onFailure?("Camera failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func configure() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: camera)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)

        session.beginConfiguration()
        session.sessionPreset = .medium
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cannotConfigure
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        configured = true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        let now = CACurrentMediaTime()
        guard now - lastFrameAt >= 0.08 else { return }
        lastFrameAt = now
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var image = CIImage(cvPixelBuffer: buffer)
        let extent = image.extent
        image = image.transformed(by: CGAffineTransform(translationX: extent.maxX, y: 0)
            .scaledBy(x: -1, y: 1))
        onFrame?(render(image: image, crop: centerCrop(in: image.extent)))
    }

    /// Fill the display without stretching: crop the camera's center to the
    /// matrix's unusually wide 4:1 aspect ratio, then reduce it to 256 pixels.
    private func centerCrop(in bounds: CGRect) -> CGRect {
        let height = bounds.width / 4
        return CGRect(x: bounds.minX, y: bounds.midY - height / 2,
                      width: bounds.width, height: height)
    }

    private func render(image: CIImage, crop: CGRect) -> PixelCanvas {
        let cropped = image.cropped(to: crop)
        guard let source = context.createCGImage(cropped, from: crop) else {
            return PixelCanvas()
        }
        // Draw the crop straight into the final matrix-sized bitmap. This
        // avoids Core Image extent/transform ordering turning a valid camera
        // frame into an off-canvas (therefore black) image.
        var bytes = [UInt8](repeating: 0, count: 32 * 8 * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        bytes.withUnsafeMutableBytes { raw in
            guard let graphics = CGContext(
                data: raw.baseAddress, width: 32, height: 8,
                bitsPerComponent: 8, bytesPerRow: 32 * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return }
            graphics.interpolationQuality = .medium
            graphics.draw(source, in: CGRect(x: 0, y: 0, width: 32, height: 8))
        }
        var canvas = PixelCanvas()
        for y in 0..<8 {
            for x in 0..<32 {
                let i = (y * 32 + x) * 4
                canvas[x, y] = .init(r: bytes[i], g: bytes[i + 1], b: bytes[i + 2])
            }
        }
        return canvas
    }

    private enum CameraError: LocalizedError {
        case noCamera, cannotConfigure
        var errorDescription: String? {
            switch self {
            case .noCamera: "No camera is available"
            case .cannotConfigure: "The camera capture session could not be configured"
            }
        }
    }
}
