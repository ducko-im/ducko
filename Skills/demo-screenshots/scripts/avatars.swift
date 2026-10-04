import AppKit

// Renders made-up emoji avatars: <localpart>.png, 256×256, emoji on a soft gradient.
// Usage: swift avatars.swift <output-dir>
let outDir = CommandLine.arguments[1]
let avatars: [(String, String, NSColor, NSColor)] = [
    ("tobias", "🦆", NSColor(red: 1.00, green: 0.86, blue: 0.35, alpha: 1), NSColor(red: 1.00, green: 0.72, blue: 0.20, alpha: 1)),
    ("lena", "🦊", NSColor(red: 0.99, green: 0.80, blue: 0.62, alpha: 1), NSColor(red: 0.98, green: 0.62, blue: 0.42, alpha: 1)),
    ("jonas", "🐼", NSColor(red: 0.74, green: 0.90, blue: 0.80, alpha: 1), NSColor(red: 0.47, green: 0.78, blue: 0.64, alpha: 1)),
    ("mia", "🐱", NSColor(red: 0.98, green: 0.78, blue: 0.86, alpha: 1), NSColor(red: 0.93, green: 0.56, blue: 0.72, alpha: 1)),
    ("priya", "🦉", NSColor(red: 0.80, green: 0.78, blue: 0.97, alpha: 1), NSColor(red: 0.58, green: 0.55, blue: 0.90, alpha: 1)),
    ("marco", "🐻", NSColor(red: 0.72, green: 0.86, blue: 0.99, alpha: 1), NSColor(red: 0.42, green: 0.68, blue: 0.95, alpha: 1)),
    ("sofia", "🐧", NSColor(red: 0.70, green: 0.92, blue: 0.95, alpha: 1), NSColor(red: 0.38, green: 0.78, blue: 0.86, alpha: 1))
]

let side = 256
for (name, emoji, top, bottom) in avatars {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: side, height: side)
    NSGradient(starting: top, ending: bottom)!.draw(in: rect, angle: -90)
    let text = NSAttributedString(string: emoji, attributes: [.font: NSFont.systemFont(ofSize: 150)])
    let size = text.size()
    text.draw(at: NSPoint(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    print(url.path)
}
