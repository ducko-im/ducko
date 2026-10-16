import SwiftUI

/// Pure-Swift HSLuv→sRGB conversion for XEP-0392 Consistent Color Generation.
///
/// HSLuv is a perceptually uniform color space designed so that colors with the
/// same lightness appear equally bright regardless of hue. This ensures that
/// nickname colors are readable and consistent across light/dark backgrounds.
enum HSLuvColor {
    private struct Vec3 {
        var x: Double
        var y: Double
        var z: Double
    }

    /// HSLuv → sRGB. `hue` 0..<360°, `saturation` 0...100, `lightness` 0...100; result in 0...1.
    static func toRGB(hue: Double, saturation: Double, lightness: Double) -> (r: Double, g: Double) {
        let rgb = toAllRGB(hue: hue, saturation: saturation, lightness: lightness)
        return (clamp01(rgb.x), clamp01(rgb.y))
    }

    static func toBlue(hue: Double, saturation: Double, lightness: Double) -> Double {
        let rgb = toAllRGB(hue: hue, saturation: saturation, lightness: lightness)
        return clamp01(rgb.z)
    }

    static func color(hue: Double, saturation: Double, lightness: Double) -> Color {
        let rgb = toAllRGB(hue: hue, saturation: saturation, lightness: lightness)
        return Color(red: clamp01(rgb.x), green: clamp01(rgb.y), blue: clamp01(rgb.z))
    }

    private static func toAllRGB(hue: Double, saturation: Double, lightness: Double) -> Vec3 {
        if lightness > 99.9999999 { return Vec3(x: 1, y: 1, z: 1) }
        if lightness < 0.00000001 { return Vec3(x: 0, y: 0, z: 0) }

        let maxChroma = maxChromaForLH(lightness: lightness, hue: hue)
        let chroma = maxChroma / 100.0 * saturation
        let hueRad = hue / 180.0 * .pi

        let luv = luvFromLCH(lightness: lightness, chroma: chroma, hueRad: hueRad)
        let xyz = xyzFromLuv(luv)
        return srgbFromXYZ(xyz)
    }

    // MARK: - CIE LUV / LCH

    private static let refU: Double = 0.19783000664283681
    private static let refV: Double = 0.46831999493879100

    private static let kappa: Double = 903.2962962962963
    private static let epsilon: Double = 0.0088564516790356308

    private static func luvFromLCH(lightness: Double, chroma: Double, hueRad: Double) -> Vec3 {
        Vec3(x: lightness, y: cos(hueRad) * chroma, z: sin(hueRad) * chroma)
    }

    private static func xyzFromLuv(_ luv: Vec3) -> Vec3 {
        if luv.x == 0 { return Vec3(x: 0, y: 0, z: 0) }

        let varU = luv.y / (13.0 * luv.x) + refU
        let varV = luv.z / (13.0 * luv.x) + refV
        let y = lToY(luv.x)
        let x = y * 9.0 * varU / (4.0 * varV)
        let z = y * (12.0 - 3.0 * varU - 20.0 * varV) / (4.0 * varV)
        return Vec3(x: x, y: y, z: z)
    }

    private static func lToY(_ l: Double) -> Double {
        if l <= 8 {
            return l / kappa
        }
        let t = (l + 16.0) / 116.0
        return t * t * t
    }

    // MARK: - XYZ → sRGB

    /// sRGB D65 matrix (from IEC 61966-2-1)
    private static let srgbMatrix: [[Double]] = [
        [3.2409699419045214, -1.5373831775700935, -0.49861076029300328],
        [-0.96924363628087983, 1.8759675015077207, 0.041555057407175613],
        [0.055630079696993609, -0.20397695888897657, 1.0569715142428786]
    ]

    private static func srgbFromXYZ(_ xyz: Vec3) -> Vec3 {
        let r = fromLinear(srgbMatrix[0][0] * xyz.x + srgbMatrix[0][1] * xyz.y + srgbMatrix[0][2] * xyz.z)
        let g = fromLinear(srgbMatrix[1][0] * xyz.x + srgbMatrix[1][1] * xyz.y + srgbMatrix[1][2] * xyz.z)
        let b = fromLinear(srgbMatrix[2][0] * xyz.x + srgbMatrix[2][1] * xyz.y + srgbMatrix[2][2] * xyz.z)
        return Vec3(x: r, y: g, z: b)
    }

    private static func fromLinear(_ c: Double) -> Double {
        if c <= 0.0031308 {
            return 12.92 * c
        }
        return 1.055 * pow(c, 1.0 / 2.4) - 0.055
    }

    // MARK: - Max Chroma

    private static func maxChromaForLH(lightness: Double, hue: Double) -> Double {
        let hueRad = hue / 180.0 * .pi
        let bounds = getBounds(lightness: lightness)
        var minLength = Double.infinity

        for bound in bounds {
            let length = lengthOfRayUntilIntersect(theta: hueRad, line: bound)
            if length >= 0 {
                minLength = min(minLength, length)
            }
        }

        return minLength
    }

    private static func lengthOfRayUntilIntersect(theta: Double, line: (slope: Double, intercept: Double)) -> Double {
        line.intercept / (sin(theta) - line.slope * cos(theta))
    }

    private static func getBounds(lightness: Double) -> [(slope: Double, intercept: Double)] {
        var bounds: [(slope: Double, intercept: Double)] = []
        bounds.reserveCapacity(6)

        let sub1 = ((lightness + 16.0) / 116.0)
        let sub1Cubed = sub1 * sub1 * sub1
        let sub2 = sub1Cubed > epsilon ? sub1Cubed : lightness / kappa

        for channel in 0 ..< 3 {
            let m1 = srgbMatrix[channel][0]
            let m2 = srgbMatrix[channel][1]
            let m3 = srgbMatrix[channel][2]

            for t: Double in [0, 1] {
                let top1 = (284_517.0 * m1 - 94839.0 * m3) * sub2
                let top2 = (838_422.0 * m3 + 769_860.0 * m2 + 731_718.0 * m1) * lightness * sub2 - 769_860.0 * t * lightness
                let bottom = (632_260.0 * m3 - 126_452.0 * m2) * sub2 + 126_452.0 * t
                bounds.append((slope: top1 / bottom, intercept: top2 / bottom))
            }
        }

        return bounds
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
