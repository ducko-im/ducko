import Foundation

/// Bounds for avatar pictures.
public enum AvatarLimits {
    /// The cap on avatar image payloads (vCard photos, PEP avatars). These arrive from peer/server data and are
    /// therefore untrusted, so payloads over the cap are dropped at ingestion (before persisting) and rejected at decode.
    public static let maxBytes = 8 * 1024 * 1024
    /// The largest picture file the user can publish as their avatar. It is scaled down before it is published, so
    /// this only bounds the memory reading and decoding it takes.
    public static let maxPictureFileBytes = 50 * 1024 * 1024
}
