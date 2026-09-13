import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Decodes the same GIFs the clock gets, so the simulator shows exactly the
/// artwork the device will — including, once the marks are animated, the same
/// frames at the same cadence.
struct PixelIcon: Sendable {
    let width: Int
    let height: Int
    /// Frame-major pixels; `frames[f][y * width + x]`.
    let frames: [[PixelCanvas.RGB]]
    /// Per-frame delay in seconds. The firmware clamps anything under 100ms,
    /// so we do too, or the simulator would run animations faster than the
    /// hardware can.
    let frameDelays: [TimeInterval]

    var frameCount: Int { frames.count }

    func frame(at time: TimeInterval) -> [PixelCanvas.RGB] {
        guard frameCount > 1 else { return frames.first ?? [] }
        let total = frameDelays.reduce(0, +)
        guard total > 0 else { return frames[0] }
        var remaining = time.truncatingRemainder(dividingBy: total)
        for (index, delay) in frameDelays.enumerated() {
            if remaining < delay { return frames[index] }
            remaining -= delay
        }
        return frames[frameCount - 1]
    }

    // MARK: Loading

    private static let cacheQueue = DispatchQueue(label: "agentclock.icons")
    nonisolated(unsafe) private static var cache: [String: PixelIcon?] = [:]

    /// Load a bundled icon by ID, memoised. Returns nil when the icon isn't
    /// bundled — pages render fine without one.
    static func bundled(id: String) -> PixelIcon? {
        cacheQueue.sync {
            if let cached = cache[id] { return cached }
            let icon = IconLibrary.bundledGIF(id: id).flatMap { decode($0) }
            cache[id] = icon
            return icon
        }
    }

    static func decode(_ data: Data) -> PixelIcon? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var frames: [[PixelCanvas.RGB]] = []
        var delays: [TimeInterval] = []
        var size: (width: Int, height: Int)?

        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let width = image.width
            let height = image.height
            if size == nil { size = (width, height) }
            guard size?.width == width, size?.height == height else { continue }
            guard let pixels = rasterize(image) else { continue }
            frames.append(pixels)
            delays.append(max(0.1, delay(of: source, at: index)))
        }

        guard let size, !frames.isEmpty else { return nil }
        return PixelIcon(width: size.width, height: size.height,
                         frames: frames, frameDelays: delays)
    }

    /// Draw into a known-layout buffer rather than trusting the image's own —
    /// GIFs arrive indexed, and reading their bytes directly means handling
    /// palettes and row padding by hand.
    private static func rasterize(_ image: CGImage) -> [PixelCanvas.RGB]? {
        let width = image.width
        let height = image.height
        var raw = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &raw, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        return (0..<(width * height)).map { index in
            let offset = index * 4
            return PixelCanvas.RGB(r: raw[offset], g: raw[offset + 1], b: raw[offset + 2])
        }
    }

    private static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double
        let clamped = gif[kCGImagePropertyGIFDelayTime] as? Double
        return unclamped ?? clamped ?? 0.1
    }
}
