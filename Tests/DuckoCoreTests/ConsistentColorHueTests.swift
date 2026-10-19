import Testing
@testable import DuckoCore

struct ConsistentColorHueTests {
    @Test(arguments: [
        ("Romeo", 327.255249),
        ("juliet@capulet.lit", 209.410400),
        ("😺", 331.199341),
        ("council", 359.994507)
    ])
    func `matches the XEP-0392 test vectors`(identifier: String, expectedHue: Double) {
        #expect(abs(ConsistentColorHue.hue(for: identifier) - expectedHue) < 0.0001)
    }

    @Test
    func `empty string produces valid hue`() {
        let hue = ConsistentColorHue.hue(for: "")
        #expect(hue >= 0)
        #expect(hue < 360)
    }
}
