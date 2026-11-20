import Foundation

/// An 8-bit grayscale image, row-major, in display orientation (y points down).
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public var pixels: [UInt8]

    public init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(pixels.count == width * height)
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Copy a luma plane that may have padded rows, rotating it into display orientation.
    /// rotation is clockwise degrees: 0, 90, 180 or 270.
    public init(plane: UnsafePointer<UInt8>, width w: Int, height h: Int, bytesPerRow: Int, rotationCW: Int) {
        switch rotationCW {
        case 90:
            // Rotate clockwise: output (x, y) = input (y, h - 1 - x); output is h wide, w tall.
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { o in
                for sy in 0..<h {
                    let row = plane + sy * bytesPerRow
                    let ox = h - 1 - sy
                    for sx in 0..<w { o[sx * h + ox] = row[sx] }
                }
            }
            self.init(width: h, height: w, pixels: out)
        case 270:
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { o in
                for sy in 0..<h {
                    let row = plane + sy * bytesPerRow
                    for sx in 0..<w { o[(w - 1 - sx) * h + sy] = row[sx] }
                }
            }
            self.init(width: h, height: w, pixels: out)
        case 180:
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { o in
                for sy in 0..<h {
                    let row = plane + sy * bytesPerRow
                    let base = (h - 1 - sy) * w
                    for sx in 0..<w { o[base + (w - 1 - sx)] = row[sx] }
                }
            }
            self.init(width: w, height: h, pixels: out)
        default:
            var out = [UInt8](repeating: 0, count: w * h)
            out.withUnsafeMutableBufferPointer { o in
                for sy in 0..<h {
                    let row = plane + sy * bytesPerRow
                    for sx in 0..<w { o[sy * w + sx] = row[sx] }
                }
            }
            self.init(width: w, height: h, pixels: out)
        }
    }

    @inline(__always) public subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }

    /// Half-size image by averaging 2x2 blocks.
    func downsampled2x() -> GrayImage {
        let w2 = width / 2, h2 = height / 2
        var out = [UInt8](repeating: 0, count: w2 * h2)
        pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                for y in 0..<h2 {
                    let r0 = 2 * y * width, r1 = r0 + width
                    for x in 0..<w2 {
                        let s = Int(p[r0 + 2 * x]) + Int(p[r0 + 2 * x + 1]) + Int(p[r1 + 2 * x]) + Int(p[r1 + 2 * x + 1])
                        o[y * w2 + x] = UInt8((s + 2) / 4)
                    }
                }
            }
        }
        return GrayImage(width: w2, height: h2, pixels: out)
    }

    /// 5x5 median filter (edges replicate), like cv2.medianBlur(img, 5).
    func median5() -> GrayImage {
        var out = [UInt8](repeating: 0, count: pixels.count)
        let w = width, h = height
        pixels.withUnsafeBufferPointer { p in
            out.withUnsafeMutableBufferPointer { o in
                var hist = [Int32](repeating: 0, count: 256)
                for y in 0..<h {
                    // Sliding histogram along the row (Huang's algorithm).
                    for i in 0..<256 { hist[i] = 0 }
                    for dy in -2...2 {
                        let yy = min(max(y + dy, 0), h - 1)
                        for dx in -2...2 {
                            let xx = min(max(dx, 0), w - 1)
                            hist[Int(p[yy * w + xx])] += 1
                        }
                    }
                    for x in 0..<w {
                        if x > 0 {
                            let xOut = min(max(x - 3, 0), w - 1), xIn = min(x + 2, w - 1)
                            for dy in -2...2 {
                                let yy = min(max(y + dy, 0), h - 1)
                                hist[Int(p[yy * w + xOut])] -= 1
                                hist[Int(p[yy * w + xIn])] += 1
                            }
                        }
                        var c: Int32 = 0, v = 0
                        while v < 255 { c += hist[v]; if c >= 13 { break }; v += 1 }
                        o[y * w + x] = UInt8(v)
                    }
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Bilinear sample; NaN when any of the four neighbours is outside the image.
    @inline(__always) func sample(_ x: Double, _ y: Double) -> Double {
        let x0 = Int(x.rounded(.down)), y0 = Int(y.rounded(.down))
        if x0 < 0 || y0 < 0 || x0 + 1 >= width || y0 + 1 >= height { return .nan }
        let fx = x - Double(x0), fy = y - Double(y0)
        let i = y0 * width + x0
        let p00 = Double(pixels[i]), p01 = Double(pixels[i + 1])
        let p10 = Double(pixels[i + width]), p11 = Double(pixels[i + width + 1])
        return (p00 * (1 - fx) + p01 * fx) * (1 - fy) + (p10 * (1 - fx) + p11 * fx) * fy
    }
}
