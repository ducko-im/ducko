import Foundation

/// Pure geometry for the contact-list window's animated, top-left-anchored
/// resize, so the anchoring, pixel rounding, and change-detection key are
/// unit-testable. All dimensions are in points. Companion to
/// `ContactListSizing`, which supplies the width/height *targets* this type
/// positions.
public enum ContactListResize {
    /// New window frame that resizes to `targetSize` while pinning the window's
    /// top-left corner: `origin.x` and the top edge (`maxY`) stay fixed, so the
    /// window grows down and to the right. Mirrors Adium's auto-sizing buddy
    /// list, whose "me" header stays put while the list grows below it. The
    /// caller converts a target *content* size to a frame size via
    /// `NSWindow.frameRect(forContentRect:)` before calling, so this stays pure
    /// `CGRect`/`CGSize` arithmetic with no AppKit dependency.
    public static func topLeftAnchoredFrame(current: CGRect, targetSize: CGSize) -> CGRect {
        let topEdge = current.maxY
        return CGRect(
            x: current.origin.x,
            y: topEdge - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )
    }

    /// Rounds a size to the backing-store pixel grid (`1 / scale` points) so
    /// sub-pixel jitter from successive layout passes doesn't read as a change
    /// and re-trigger the resize animation. Falls back to whole points for a
    /// non-positive scale.
    public static func pixelRounded(_ size: CGSize, scale: CGFloat) -> CGSize {
        guard scale > 0 else {
            return CGSize(width: size.width.rounded(), height: size.height.rounded())
        }
        return CGSize(
            width: (size.width * scale).rounded() / scale,
            height: (size.height * scale).rounded() / scale
        )
    }

    /// The state an `updateNSView` pass compares against the last applied pass
    /// to decide whether the row set or the window's size changed; when both
    /// this and the row heights are equal, the pass bails without re-triggering
    /// animation.
    ///
    /// `rowIDs` are the section-qualified, account-qualified row identities, so
    /// a same-JID peer rostered on two accounts (and a multi-group contact
    /// rendered in more than one section) stays distinct — otherwise the
    /// bail-when-unchanged guard and the row diff would disagree and miss an
    /// insert/remove. `roundedContentSize` reflects total chrome + content
    /// size, so a chrome-only change (a banner or the search field appearing)
    /// still busts the key even when the rows are unchanged.
    public struct LayoutKey: Equatable, Sendable {
        public let rowIDs: [String]
        public let roundedContentSize: CGSize

        public init(rowIDs: [String], contentSize: CGSize, scale: CGFloat) {
            self.rowIDs = rowIDs
            self.roundedContentSize = ContactListResize.pixelRounded(contentSize, scale: scale)
        }
    }
}
