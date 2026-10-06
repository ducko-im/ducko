import AppKit
import DuckoCore
import SwiftUI

/// Caps on name and row measurement so a server-controlled roster (very many
/// entries or pathologically long names) can't drive unbounded layout work.
private let maxMeasuredNames = 200
private let maxMeasuredNameLength = 64
private let maxMeasuredRows = 200

/// Cheap fingerprint of everything the fitted-width measurement reads, so a
/// reconcile whose width inputs are unchanged reuses the cached width instead
/// of re-running the font measurement over the names. `.auto` carries the exact
/// capped strings `measuredNames()` produces — so any rename or account-label
/// change busts it; `.manual` carries the window content width the manual path
/// returns. (`measuredNames()` itself still runs each reconcile to build the key;
/// the memo only skips the per-name `NSString` sizing.)
private enum WidthMeasurementKey: Equatable {
    case manual(width: CGFloat)
    case auto(names: [String], avatarSize: CGFloat, maxWidth: CGFloat)
}

/// Whether a measured row shows its optional second (caption) line, the only
/// per-row content that moves its height — every text element is a single line,
/// so the line's *text* doesn't matter, only its presence.
private enum RowHeightSignature: Equatable {
    case header
    case contact(hasSecondLine: Bool)
    case room(hasSecondLine: Bool)
}

/// Cheap fingerprint of everything the per-row height measurement reads, so a
/// reconcile whose height inputs are unchanged reuses the cached heights instead
/// of laying out up to `maxMeasuredRows` `NSHostingView`s. Properties are read
/// only via the synthesized `==`, which Periphery can't see.
private struct HeightMeasurementKey: Equatable {
    // periphery:ignore
    let width: CGFloat
    // periphery:ignore
    let totalRowCount: Int
    // periphery:ignore
    let maxListHeight: CGFloat
    // periphery:ignore
    let rows: [RowHeightSignature]
    // Not covered by `rows`: compact rows drop the avatar as well as the
    // caption, so a row with no second line changes height too.
    // periphery:ignore
    let isCompact: Bool
}

/// The memoized output of the per-row height measurement.
struct MeasuredGeometry {
    let newHeights: [CGFloat]
    let listHeight: CGFloat
}

@MainActor
final class ContactListMeasurement {
    private static let nameFont = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
    private static let estimatedRowChrome: CGFloat = 12
    private var measuringHost: NSHostingView<ContactListCellContent>?
    private var widthMemo: (key: WidthMeasurementKey, width: CGFloat)?
    private var heightMemo: (key: HeightMeasurementKey, geometry: MeasuredGeometry)?

    /// Content width the rows render at, memoized: the auto-fit width when
    /// horizontal auto-size is on, otherwise the window's current content
    /// width (the coordinator never drives a manual axis). The capped name
    /// scan runs each reconcile to build the key; on a match the per-name font
    /// measurement and fitted-width calc are what's skipped.
    func contentWidth(inputs: ContactListTableInputs, manualWidth: CGFloat) -> CGFloat {
        let avatarSize: CGFloat = inputs.isCompact ? 0 : AvatarView.defaultSize
        let key: WidthMeasurementKey = inputs.autoSizeHorizontal
            ? .auto(names: measuredNames(inputs: inputs), avatarSize: avatarSize, maxWidth: CGFloat(ContactListSizing.clampMaxWidth(inputs.maxWidthPreference)))
            : .manual(width: manualWidth)
        if let widthMemo, widthMemo.key == key { return widthMemo.width }
        let width: CGFloat = switch key {
        case let .auto(names, avatarSize, maxWidth): fittedContentWidth(names: names, avatarSize: avatarSize, maxWidth: maxWidth)
        case let .manual(width): width
        }
        widthMemo = (key, width)
        return width
    }

    /// The capped contact/room names the fitted-width scan measures, in row
    /// order: each contact's display name plus its account-disambiguation
    /// label, each room's title; headers skipped. Capped so a pathological
    /// roster can't drive unbounded measurement. Shared with the width memo
    /// key so the cache invalidates on exactly the renames and account-label
    /// changes that move the fitted width.
    private func measuredNames(inputs: ContactListTableInputs) -> [String] {
        guard let environment = inputs.environment else { return [] }
        var names: [String] = []
        for row in inputs.incomingRows where names.count < maxMeasuredNames {
            let name: String? = switch row {
            case .header:
                nil
            case let .contact(_, contact):
                measuringName(for: contact, environment: environment)
            case let .room(room):
                room.displayTitle
            }
            guard let name else { continue }
            names.append(String(name.prefix(maxMeasuredNameLength)))
        }
        return names
    }

    /// Fits the window width to the widest measured name, via the row font.
    /// `avatarSize` and `maxWidth` come from the memo key so the cached width
    /// and the key that gates it are computed from identical inputs.
    private func fittedContentWidth(names: [String], avatarSize: CGFloat, maxWidth: CGFloat) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.nameFont]
        let maxNameWidth = names.reduce(CGFloat(0)) { max($0, ($1 as NSString).size(withAttributes: attributes).width) }
        return ContactListSizing.fittedWidth(
            maxNameWidth: maxNameWidth,
            avatarSize: avatarSize,
            rowChrome: ContactListWidthMetrics.rowChrome,
            floorWidth: ContactListWidthMetrics.floor,
            maxWidth: maxWidth
        )
    }

    private func measuringName(for contact: Contact, environment: AppEnvironment) -> String {
        guard let label = AccountIndicator.label(
            for: contact.accountID, bareJID: contact.jid.description,
            accountService: environment.accountService, rosterService: environment.rosterService
        ) else {
            return contact.displayName
        }
        return "\(contact.displayName)  \(label)"
    }

    /// The per-row heights and the auto-sized list height, memoized: on a key
    /// match the per-row `NSHostingView` layout loop is skipped.
    func heights(inputs: ContactListTableInputs, contentWidth: CGFloat, maxListHeight: CGFloat, cellContent: (ContactListRow) -> ContactListCellContent?) -> MeasuredGeometry {
        let measureCount = min(inputs.incomingRows.count, maxMeasuredRows)
        // Flat height for a row that is not measured: its tallest fixed element,
        // the avatar or the name's line in a compact row, plus an allowance for
        // the padding around it.
        let tallestElement = inputs.isCompact ? NSLayoutManager().defaultLineHeight(for: Self.nameFont) : AvatarView.defaultSize
        let flatRowHeight = tallestElement + Self.estimatedRowChrome
        let key = HeightMeasurementKey(
            width: contentWidth,
            totalRowCount: inputs.incomingRows.count,
            maxListHeight: maxListHeight,
            rows: (0 ..< measureCount).map { rowHeightSignature(for: inputs.incomingRows[$0], inputs: inputs) },
            isCompact: inputs.isCompact
        )
        if let heightMemo, heightMemo.key == key { return heightMemo.geometry }
        let measuredHeights = (0 ..< measureCount).map { measureHeight(content: cellContent(inputs.incomingRows[$0]), width: contentWidth, fallback: flatRowHeight) }
        let newHeights = (0 ..< inputs.incomingRows.count).map { $0 < measureCount ? measuredHeights[$0] : flatRowHeight }
        let listHeight = targetListHeight(
            measuredHeights: measuredHeights,
            totalRowCount: inputs.incomingRows.count,
            flatRowHeight: flatRowHeight, maxListHeight: maxListHeight
        )
        let geometry = MeasuredGeometry(newHeights: newHeights, listHeight: listHeight)
        heightMemo = (key, geometry)
        return geometry
    }

    /// The layout-affecting fingerprint of one row: its kind, and for the two
    /// kinds with an optional caption line, whether that line shows. Derives
    /// `hasSecondLine` from the same `ContactCaption`/`RoomCaption` resolvers
    /// the row views render from, so the memo predicts the 1- vs 2-line height
    /// without hosting the view and can't drift from what renders.
    private func rowHeightSignature(for row: ContactListRow, inputs: ContactListTableInputs) -> RowHeightSignature {
        switch row {
        case .header:
            return .header
        case let .contact(_, contact):
            return .contact(hasSecondLine: contactHasSecondLine(contact, inputs: inputs))
        case let .room(room):
            return .room(hasSecondLine: roomHasSecondLine(room, inputs: inputs))
        }
    }

    private func contactHasSecondLine(_ contact: Contact, inputs: ContactListTableInputs) -> Bool {
        guard let environment = inputs.environment else { return false }
        return ContactCaption.resolve(for: contact, isCompact: inputs.isCompact, presenceService: environment.presenceService).hasSecondLine
    }

    private func roomHasSecondLine(_ room: Conversation, inputs: ContactListTableInputs) -> Bool {
        guard let environment = inputs.environment else { return false }
        return RoomCaption.resolve(for: room, isCompact: inputs.isCompact, chatService: environment.chatService).hasSecondLine
    }

    /// Self-sized height of one row at the target content width, via a
    /// reused off-screen `NSHostingView`.
    private func measureHeight(content: ContactListCellContent?, width: CGFloat, fallback: CGFloat) -> CGFloat {
        guard var content else { return fallback }
        content.measuresHeightOnly = true
        let host: NSHostingView<ContactListCellContent>
        if let measuringHost {
            host = measuringHost
            host.rootView = content
        } else {
            host = NSHostingView(rootView: content)
            measuringHost = host
        }
        host.setFrameSize(NSSize(width: width, height: 0))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// The list's auto-sized height. An overflowing roster (more than
    /// `maxMeasuredRows`) takes `fittedHeight`'s fallback — which clamps to
    /// the screen cap and scrolls — instead of a truncated measured sum.
    private func targetListHeight(measuredHeights: [CGFloat], totalRowCount: Int, flatRowHeight: CGFloat, maxListHeight: CGFloat) -> CGFloat {
        let overflowing = totalRowCount > maxMeasuredRows
        let measured = overflowing ? 0 : measuredHeights.reduce(0, +)
        return ContactListSizing.fittedHeight(
            measuredHeight: measured,
            fallbackHeight: CGFloat(totalRowCount) * flatRowHeight,
            maxHeight: maxListHeight
        )
    }
}
