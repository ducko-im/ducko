import Foundation
import Testing
@testable import DuckoUI

struct HSLuvColorTests {
    @Test
    func `black at zero lightness`() {
        let rg = HSLuvColor.toRGB(hue: 0, saturation: 100, lightness: 0)
        let b = HSLuvColor.toBlue(hue: 0, saturation: 100, lightness: 0)
        #expect(rg.r == 0)
        #expect(rg.g == 0)
        #expect(b == 0)
    }

    @Test
    func `white at full lightness`() {
        let rg = HSLuvColor.toRGB(hue: 0, saturation: 100, lightness: 100)
        let b = HSLuvColor.toBlue(hue: 0, saturation: 100, lightness: 100)
        #expect(rg.r == 1)
        #expect(rg.g == 1)
        #expect(b == 1)
    }

    @Test
    func `mid lightness produces valid RGB`() {
        let rg = HSLuvColor.toRGB(hue: 180, saturation: 100, lightness: 50)
        let b = HSLuvColor.toBlue(hue: 180, saturation: 100, lightness: 50)
        #expect(rg.r >= 0 && rg.r <= 1)
        #expect(rg.g >= 0 && rg.g <= 1)
        #expect(b >= 0 && b <= 1)
    }

    @Test
    func `different hues produce different colors`() {
        let c1 = HSLuvColor.toRGB(hue: 0, saturation: 100, lightness: 50)
        let c2 = HSLuvColor.toRGB(hue: 120, saturation: 100, lightness: 50)
        let isDifferent = c1.r != c2.r || c1.g != c2.g
        #expect(isDifferent)
    }

    @Test(arguments: [(hue: 0.0, hex: "#EA0064"), (hue: 200.0, hex: "#00848B"), (hue: 300.0, hex: "#CD00E2")])
    func `full saturation matches the reference HSLuv color`(hue: Double, hex: String) {
        let rg = HSLuvColor.toRGB(hue: hue, saturation: 100, lightness: 50)
        let b = HSLuvColor.toBlue(hue: hue, saturation: 100, lightness: 50)
        let channels = [rg.r, rg.g, b].map { Int(($0 * 255).rounded()) }
        #expect("#" + channels.map { String(format: "%02X", $0) }.joined() == hex)
    }

    @Test
    func `zero saturation produces grey`() {
        let rg = HSLuvColor.toRGB(hue: 0, saturation: 0, lightness: 50)
        let b = HSLuvColor.toBlue(hue: 0, saturation: 0, lightness: 50)
        let tolerance = 0.001
        let rEqualsG = abs(rg.r - rg.g) < tolerance
        let gEqualsB = abs(rg.g - b) < tolerance
        #expect(rEqualsG)
        #expect(gEqualsB)
    }

    @Test
    func `all hues at fixed lightness produce valid colors`() {
        for hue in stride(from: 0.0, to: 360.0, by: 30.0) {
            let rg = HSLuvColor.toRGB(hue: hue, saturation: 100, lightness: 65)
            let b = HSLuvColor.toBlue(hue: hue, saturation: 100, lightness: 65)
            #expect(rg.r >= 0 && rg.r <= 1)
            #expect(rg.g >= 0 && rg.g <= 1)
            #expect(b >= 0 && b <= 1)
        }
    }
}
