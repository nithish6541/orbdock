import AppKit

/// The glow's living state. Advanced once per frame; everything eases, nothing jumps.
final class GlowModel {
    /// The artwork being left behind and the one flowing in. Equal when no transition is running.
    private(set) var from: Swatch = .idle
    private(set) var to: Swatch = .idle
    private var rawProgress: Double = 1
    private let fusionDuration: Double = 3.6

    /// 0 = settled (paused), 1 = awake (playing). Driven by a critically damped spring.
    private(set) var energy: Double = 0
    private var energyVelocity: Double = 0
    var targetEnergy: Double = 0

    private(set) var motionTime: Double = 0

    /// Eased progress of the current fusion, 0…1.
    var progress: Double {
        let t = rawProgress
        return t * t * (3 - 2 * t)
    }

    var isTransitioning: Bool {
        rawProgress < 1 || abs(targetEnergy - energy) > 0.01 || abs(energyVelocity) > 0.01
    }

    /// Start fusing into new artwork. If a fusion is already underway, the dominant side becomes the new origin.
    func fuse(into s: Swatch) {
        from = rawProgress < 0.5 ? from : to
        to = s
        rawProgress = 0
    }

    /// Jump straight to new artwork, used when appearing from nothing.
    func set(_ s: Swatch) {
        from = s; to = s; rawProgress = 1
    }

    func step(_ dt: Double) {
        let dt = min(dt, 0.1)

        // Wake a little quicker than we settle: arriving feels responsive, leaving feels calm.
        let omega = targetEnergy > energy ? 2.2 : 1.2
        let accel = omega * omega * (targetEnergy - energy) - 2 * omega * energyVelocity
        energyVelocity += accel * dt
        energy = max(0, min(1, energy + energyVelocity * dt))

        motionTime += dt * (0.03 + 0.97 * energy)

        if rawProgress < 1 {
            rawProgress = min(1, rawProgress + dt / fusionDuration)
            if rawProgress >= 1 { from = to }
        }
    }
}

/// Paints the album artwork across the Dock as a slowly swirling, blurred wash.
///
/// The Dock looks through a wide, drifting, gently rotating window onto the blurred cover, and the lookup
/// point is bent by flowing noise so the colors meander like ink in water. Colors keep the proportions and
/// neighbors they have on the cover. Rendered tiny and scaled up; the Dock's glass softens it further.
enum GlowRenderer {
    static func image(width w: Int, height h: Int, model: GlowModel) -> CGImage? {
        render(width: w, height: h, from: model.from, to: model.to, progress: model.progress,
               energy: model.energy, m: model.motionTime)
    }

    static func render(width w: Int, height h: Int, from: Swatch, to: Swatch, progress: Double,
                       energy: Double, m: Double) -> CGImage? {
        guard w > 0, h > 0 else { return nil }
        let aspect = Double(w) / Double(h)
        let fusing = progress > 0.001 && progress < 0.999
        let primary = progress >= 0.999 ? to : from

        // The window onto the cover: a horizontal band that drifts up and down through the artwork,
        // slides a little sideways, and slowly tilts, so different parts of the cover surface over time.
        let band = 0.42
        let bandCenter = 0.26 * sin(m * 0.061 + 1)
        let slide = 0.05 * sin(m * 0.052)
        let tilt = 0.3 * sin(m * 0.043)
        let cosT = cos(tilt), sinT = sin(tilt)

        let warp = 0.5 + 0.5 * energy
        let flow = m * 0.14
        let chromaScale = 0.85 + 0.15 * energy
        let dim = -0.03 * (1 - energy)
        // The fusion front blooms out from the middle of the Dock.
        let front = progress * 1.3 - 0.15

        var pixels = [UInt8](repeating: 255, count: w * h * 4)
        for py in 0..<h {
            let y = (Double(py) + 0.5) / Double(h)
            for px in 0..<w {
                let x = (Double(px) + 0.5) / Double(w) * aspect

                // Flowing distortion, measured in Dock heights.
                let dx = warp * 0.9 * fbm(x * 0.45 + flow, y * 0.9 + 3.1)
                let dy = warp * 0.35 * fbm(x * 0.45 + 7.3, y * 0.9 - flow * 0.8)

                // Into cover space: stretch the cover along the Dock, look through the band, tilt.
                let pu = (x + dx) / aspect - 0.5
                let pv = (y - 0.5 + dy) * band + bandCenter
                let u = reflect(0.5 + slide + 0.92 * (pu * cosT - pv * sinT))
                let v = reflect(0.5 + pu * sinT + pv * cosT)

                var c = primary.sample(u, v)
                if fusing {
                    let b = to.sample(u, v)
                    let dist = abs(x - aspect / 2) / (aspect / 2)
                    let edge = 0.72 * dist + 0.28 * (noise(x * 0.8 + 11.7, y * 1.6 + 2.3) * 0.5 + 0.5)
                    let t = smoothstep(edge - 0.12, edge + 0.12, front)
                    c = c.lerp(to: b, t)
                    // A faint seam of light where the two albums meet.
                    c.L += 0.07 * 4 * t * (1 - t)
                }

                // Quieter at rest, plus a gentle shimmer so even still areas feel alive.
                c.a *= chromaScale; c.b *= chromaScale
                c.L += dim + 0.02 * energy * noise(x * 1.1 - flow * 2, y * 2.2 + flow)

                let rgb = c.rgb
                let i = (py * w + px) * 4
                pixels[i] = UInt8(rgb.r * 255 + 0.5)
                pixels[i + 1] = UInt8(rgb.g * 255 + 0.5)
                pixels[i + 2] = UInt8(rgb.b * 255 + 0.5)
            }
        }

        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Mirror coordinates back into 0…1 so the window never runs off the edge of the cover.
    @inline(__always)
    private static func reflect(_ t: Double) -> Double {
        let r = abs(t).truncatingRemainder(dividingBy: 2)
        return r > 1 ? 2 - r : r
    }

    // MARK: - Noise

    @inline(__always)
    private static func hash(_ i: Int, _ j: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: i &* 374761393 &+ j &* 668265263)
        h = (h ^ (h >> 13)) &* 1274126177
        h ^= h >> 16
        return Double(h) / Double(UInt32.max) * 2 - 1
    }

    /// Smooth value noise in -1…1.
    @inline(__always)
    private static func noise(_ x: Double, _ y: Double) -> Double {
        let xf = x.rounded(.down), yf = y.rounded(.down)
        let i = Int(xf), j = Int(yf)
        let fx = x - xf, fy = y - yf
        let ux = fx * fx * fx * (fx * (fx * 6 - 15) + 10)
        let uy = fy * fy * fy * (fy * (fy * 6 - 15) + 10)
        let a = hash(i, j), b = hash(i + 1, j), c = hash(i, j + 1), d = hash(i + 1, j + 1)
        return a + (b - a) * ux + (c - a) * uy + (a - b - c + d) * ux * uy
    }

    @inline(__always)
    private static func fbm(_ x: Double, _ y: Double) -> Double {
        0.65 * noise(x, y) + 0.35 * noise(x * 2.03 + 1.7, y * 2.03 - 4.1)
    }

    @inline(__always)
    private static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}

/// Renders an app icon (a rounded tile of the glow) for Finder.
func renderIcon(to path: String, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    let ctx = g.cgContext
    let s = CGFloat(pixels)
    let tile = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    ctx.addPath(CGPath(roundedRect: tile, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil))
    ctx.clip()
    let swatch = Swatch.fallback(for: "Orb")
    if let image = GlowRenderer.render(width: 48, height: 48, from: swatch, to: swatch, progress: 1, energy: 1, m: 4) {
        ctx.interpolationQuality = .high
        ctx.draw(image, in: tile)
    }
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
}
