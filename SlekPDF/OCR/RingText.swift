import CoreGraphics
import Foundation

/// Text set around a round seal or emblem (“ក្រសួងសាធារណការ និងដឹកជញ្ជូន” over the top, “MINISTRY OF PUBLIC WORKS
/// AND TRANSPORT” under the bottom). The OCR engines read straight lines only, so the ring is unrolled into straight
/// strips first: the top arc read clockwise with the letters' tops outward, the bottom arc read anticlockwise with
/// their tops inward (as such seals are printed). Each strip is ink on white, whatever the colours were.
nonisolated enum RingText {
    struct Strip {
        /// The unrolled band, letters upright, reading left to right; ink black on white.
        let image: CGImage
        /// Where the arc is on the page (pixels, top-left origin), for the line's box.
        let pageRect: CGRect
        let center: CGPoint
        let inner: CGFloat
        let outer: CGFloat
        /// Whether `point` (page pixels) lies on this arc's half of the ring band.
        func ringContains(_ point: CGPoint) -> Bool {
            let distance = hypot(point.x - center.x, point.y - center.y)
            return distance >= inner * 0.95 && distance <= outer * 1.03 && (point.y < center.y) == (pageRect.midY < center.y)
        }
    }

    /// Whether `rect` (pixels) could be a round seal: roughly square and not tiny.
    static func isRoundCandidate(_ rect: CGRect, page: CGSize) -> Bool {
        let aspect = rect.width / max(rect.height, 1)
        return aspect > 0.8 && aspect < 1.25 && min(rect.width, rect.height) >= min(page.width, page.height) * 0.2
    }

    /// The top and bottom arcs of the ring inside `rect`, unrolled. The band is the outer quarter of the circle.
    static func strips(of image: CGImage, circleIn rect: CGRect) -> [Strip] {
        let page = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let circle = rect.intersection(page)
        guard !circle.isNull, let pixels = grayPixels(image) else { return [] }
        let center = CGPoint(x: circle.midX, y: circle.midY)
        let outer = min(circle.width, circle.height) / 2 * 0.98
        let inner = outer * 0.74
        let middle = (outer + inner) / 2
        let thickness = Int(outer - inner)
        // Top: φ from left (π) over the top (3π/2, image y down) to right (2π), tops outward (row 0 = outer edge).
        // Bottom: φ from left (π) under the bottom (π/2) to right (0), tops inward (row 0 = inner edge).
        let arcs: [(start: CGFloat, sweep: CGFloat, outwardTops: Bool, top: Bool)] = [
            (.pi - overlap, .pi + 2 * overlap, true, true),
            (.pi + overlap, -(.pi + 2 * overlap), false, false),
        ]
        return arcs.compactMap { arc in
            let width = Int(abs(arc.sweep) * middle)
            guard width > 16, thickness > 8 else { return nil }
            var strip = [UInt8](repeating: 255, count: width * thickness)
            for x in 0..<width {
                let phi = arc.start + arc.sweep * CGFloat(x) / CGFloat(width)
                let (c, s) = (cos(phi), sin(phi))
                for y in 0..<thickness {
                    let r = arc.outwardTops ? outer - CGFloat(y) : inner + CGFloat(y)
                    let px = Int(center.x + r * c), py = Int(center.y + r * s)
                    guard px >= 0, py >= 0, px < image.width, py < image.height else { continue }
                    strip[y * width + x] = pixels[py * image.width + px]
                }
            }
            guard let ink = inkOnWhite(strip, width: width, height: thickness) else { return nil }
            let band = CGRect(x: center.x - outer, y: arc.top ? center.y - outer : center.y + inner,
                              width: 2 * outer, height: outer - inner)
            return Strip(image: ink, pageRect: band.intersection(page), center: center, inner: inner, outer: outer)
        }
    }

    /// The share of a strip at each end that lies past the horizontal (see `strips`).
    static let endFraction = Double(overlap / (.pi + 2 * overlap))
    static let overlap: CGFloat = 0.35

    // MARK: Pixels

    /// 8-bit luminance, rows top to bottom.
    static func grayPixels(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        let ok = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? pixels : nil
    }

    /// Otsu's threshold; the smaller side is the ink (white letters on a coloured ring, or dark ones on white).
    static func inkOnWhite(_ gray: [UInt8], width: Int, height: Int) -> CGImage? {
        var histogram = [Int](repeating: 0, count: 256)
        for value in gray { histogram[Int(value)] += 1 }
        let total = gray.count
        let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
        var sumBack = 0.0, weightBack = 0, best = 0.0, threshold = 128
        for t in 0..<256 {
            weightBack += histogram[t]
            guard weightBack > 0, weightBack < total else { continue }
            sumBack += Double(t * histogram[t])
            let meanBack = sumBack / Double(weightBack), meanFore = (sum - sumBack) / Double(total - weightBack)
            let between = Double(weightBack) * Double(total - weightBack) * pow(meanBack - meanFore, 2)
            if between > best { best = between; threshold = t }
        }
        let dark = gray.filter { Int($0) <= threshold }.count
        let inkIsDark = dark <= total - dark
        let out = gray.map { value -> UInt8 in
            let isInk = inkIsDark ? Int(value) <= threshold : Int(value) > threshold
            return isInk ? 0 : 255
        }
        return CGImage.gray(out, width: width, height: height)
    }
}

nonisolated extension CGImage {
    /// An 8-bit grayscale image of `pixels` (rows top to bottom).
    static func gray(_ pixels: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
