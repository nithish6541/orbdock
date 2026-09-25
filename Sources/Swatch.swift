import AppKit

/// A tiny, heavily blurred copy of the album artwork in OKLab, ready to be swirled across the Dock.
/// Keeping the artwork itself (not a list of extracted colors) preserves where colors sit and how much
/// of each there is, so a mostly-blue cover with a small orange sun stays mostly blue with a warm glow.
struct Swatch {
    static let size = 20

    let texels: [OKLab]   // size × size, row-major, row 0 at the top

    /// Bilinear sample, u,v in 0…1. The texture is blurred enough that linear blending shows no seams.
    @inline(__always)
    func sample(_ u: Double, _ v: Double) -> OKLab {
        let n = Swatch.size
        let x = u * Double(n - 1), y = v * Double(n - 1)
        let x0 = min(n - 2, max(0, Int(x))), y0 = min(n - 2, max(0, Int(y)))
        let fx = max(0, min(1, x - Double(x0))), fy = max(0, min(1, y - Double(y0)))
        let a = texels[y0 * n + x0], b = texels[y0 * n + x0 + 1]
        let c = texels[(y0 + 1) * n + x0], d = texels[(y0 + 1) * n + x0 + 1]
        return a.lerp(to: b, fx).lerp(to: c.lerp(to: d, fx), fy)
    }

    // MARK: - Sources

    static func from(artwork image: NSImage) -> Swatch? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let n = size
        var pixels = [UInt8](repeating: 0, count: n * n * 4)
        guard let ctx = CGContext(data: &pixels, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
        let texels = (0..<n * n).map { i in
            OKLab(r: Double(pixels[i * 4]) / 255, g: Double(pixels[i * 4 + 1]) / 255, b: Double(pixels[i * 4 + 2]) / 255)
        }
        return Swatch(refining: texels)
    }

    /// When artwork can't be read: soft bands of a gentle analogous palette, seeded by the album.
    static func fallback(for key: String) -> Swatch {
        var rng = SeededRandom(seed: stableHash(key))
        let hue = rng.next() * 360
        let colors = [
            OKLab(L: 0.52, chroma: 0.09, hueDegrees: hue),
            OKLab(L: 0.68, chroma: 0.12, hueDegrees: hue + 28),
            OKLab(L: 0.44, chroma: 0.10, hueDegrees: hue - 32),
            OKLab(L: 0.78, chroma: 0.07, hueDegrees: hue + 70),
        ]
        return bands(colors)
    }

    /// A quiet pearl. Only seen before any artwork has arrived.
    static let idle = bands([
        OKLab(L: 0.86, chroma: 0.012, hueDegrees: 70),
        OKLab(L: 0.80, chroma: 0.045, hueDegrees: 300),
        OKLab(L: 0.84, chroma: 0.040, hueDegrees: 235),
        OKLab(L: 0.88, chroma: 0.038, hueDegrees: 55),
    ])

    private static func bands(_ colors: [OKLab]) -> Swatch {
        let n = size
        let texels = (0..<n * n).map { i -> OKLab in
            let x = Double(i % n) / Double(n), y = Double(i / n) / Double(n)
            let t = (x * 2.2 + y * 0.8).truncatingRemainder(dividingBy: 1)
            let f = t * Double(colors.count)
            let k = Int(f) % colors.count
            return colors[k].lerp(to: colors[(k + 1) % colors.count], f - f.rounded(.down))
        }
        return Swatch(refining: texels)
    }

    // MARK: - Refinement

    /// Blur, then tame: keep the artwork's light/dark structure, but cap saturation per hue so blues
    /// and violets (which screens render intensely and eyes read as loud) sit level with warm colors.
    private init(refining raw: [OKLab]) {
        let blurred = Swatch.blur(Swatch.blur(Swatch.blur(Swatch.blur(raw))))
        let meanL = blurred.map(\.L).reduce(0, +) / Double(blurred.count)
        texels = blurred.map { c in
            let L = max(0.3, min(0.86, meanL + (c.L - meanL) * 1.12))
            let chroma = min(c.chroma * 1.05, Swatch.chromaCeiling(hue: c.hue))
            return OKLab(L: L, a: chroma * cos(c.hue), b: chroma * sin(c.hue))
        }
    }

    /// Highest chroma allowed for a hue: full for warm hues, reined in across cyan → blue → violet.
    /// (OKLab hue ≈ 195° cyan, 264° blue, 330° magenta, 30° red, 110° yellow.)
    static func chromaCeiling(hue: Double) -> Double {
        let coolness = max(0, cos(hue - 240 * .pi / 180))
        return 0.19 - 0.075 * coolness
    }

    /// 3×3 box blur with clamped edges.
    private static func blur(_ t: [OKLab]) -> [OKLab] {
        let n = size
        return (0..<n * n).map { i in
            let x = i % n, y = i / n
            var L = 0.0, a = 0.0, b = 0.0
            for dy in -1...1 {
                for dx in -1...1 {
                    let c = t[min(n - 1, max(0, y + dy)) * n + min(n - 1, max(0, x + dx))]
                    L += c.L; a += c.a; b += c.b
                }
            }
            return OKLab(L: L / 9, a: a / 9, b: b / 9)
        }
    }
}

// MARK: - Determinism helpers

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}

func stableHash(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325
    for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
    return h
}
