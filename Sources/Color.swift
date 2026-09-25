import CoreGraphics
import Foundation

/// A color in OKLab — a perceptual space where blending two colors
/// passes through natural in-between hues instead of muddy greys.
struct OKLab: Equatable {
    var L: Double
    var a: Double
    var b: Double

    var chroma: Double { (a * a + b * b).squareRoot() }
    var hue: Double { atan2(b, a) }

    init(L: Double, a: Double, b: Double) {
        self.L = L; self.a = a; self.b = b
    }

    init(L: Double, chroma: Double, hueDegrees: Double) {
        let h = hueDegrees * .pi / 180
        self.init(L: L, a: chroma * cos(h), b: chroma * sin(h))
    }

    init(r: Double, g: Double, b bl: Double) {
        func lin(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = lin(r), g = lin(g), b = lin(bl)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        self.L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        self.a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        self.b = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    }

    var rgb: (r: Double, g: Double, b: Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func enc(_ c: Double) -> Double {
            let c = max(0, min(1, c))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        return (
            enc(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            enc(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            enc(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    func cgColor(alpha: Double = 1) -> CGColor {
        let c = rgb
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }

    func distance(to o: OKLab) -> Double {
        let dL = L - o.L, da = a - o.a, db = b - o.b
        return (dL * dL + da * da + db * db).squareRoot()
    }

    func lerp(to o: OKLab, _ t: Double) -> OKLab {
        OKLab(L: L + (o.L - L) * t, a: a + (o.a - a) * t, b: b + (o.b - b) * t)
    }

    /// Returns a copy with lightness shifted and chroma scaled.
    func adjusted(dL: Double = 0, chromaScale: Double = 1, rotateDegrees: Double = 0) -> OKLab {
        let h = hue + rotateDegrees * .pi / 180
        let c = chroma * chromaScale
        return OKLab(L: max(0, min(1, L + dL)), a: c * cos(h), b: c * sin(h))
    }

    func clamped(L lo: Double, _ hi: Double, maxChroma: Double) -> OKLab {
        let c = min(chroma, maxChroma)
        let h = hue
        return OKLab(L: max(lo, min(hi, L)), a: c * cos(h), b: c * sin(h))
    }
}
