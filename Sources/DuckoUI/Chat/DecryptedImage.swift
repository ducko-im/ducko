import AppKit

/// An image decrypted for display, with the bytes it was decoded from, which Save writes as they are.
struct DecryptedImage {
    let image: NSImage
    let bytes: [UInt8]

    /// Nil for bytes that do not decode as an image.
    init?(bytes: [UInt8]) {
        guard let image = NSImage(data: Data(bytes)) else { return nil }
        self.image = image
        self.bytes = bytes
    }
}
