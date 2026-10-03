import AppKit
import DuckoCore
import SwiftUI

struct ChatTabBarView: View {
    @Environment(AppEnvironment.self) private var environment
    let container: ChatContainerState

    /// Below this a tab can't show a usable label, so further tabs spill into the
    /// overflow menu rather than shrinking past legibility.
    private let minTabWidth: CGFloat = 90
    /// Cap so one very long name can't crowd everything else out; a name wider
    /// than this truncates even when the bar has room.
    private let maxTabWidth: CGFloat = 320
    /// Footprint reserved for the overflow dropdown when it's shown.
    private let controlWidth: CGFloat = 30
    private let barHeight: CGFloat = 34
    /// Symmetric inset large enough to keep tabs clear of the window's rounded
    /// bottom corners — the bar sits at the very bottom edge, so a smaller inset
    /// lets the leading/trailing tabs run into the corner curve.
    private let horizontalInset: CGFloat = 12
    private let tabSpacing: CGFloat = 4

    var body: some View {
        // GeometryReader takes the offered width and proposes no minimum of its
        // own, so the tab content never forces the chat window wider or blocks it
        // from shrinking — tabs are laid out within whatever width the window gives.
        GeometryReader { proxy in
            let tabs = container.orderedTabs
            let available = proxy.size.width - horizontalInset * 2
            let intrinsics = Dictionary(uniqueKeysWithValues: tabs.map { ($0, intrinsicWidth(for: $0)) })
            let visibleCount = visibleCount(available: available, intrinsics: tabs.map { intrinsics[$0] ?? minTabWidth })
            let split = partition(tabs, visibleCount: visibleCount)
            let hasOverflow = !split.overflow.isEmpty
            let budget = (hasOverflow ? available - controlWidth : available) - gaps(split.visible.count)
            let widths = distribute(split.visible.map { intrinsics[$0] ?? minTabWidth }, budget: budget)

            // Outer spacing 0 so the Spacer/overflow add no stray gaps; the inner
            // HStack owns the inter-tab spacing, which the width math budgets for so
            // the chips never overflow the padded width and shove the trailing tab
            // into the corner.
            HStack(spacing: 0) {
                HStack(spacing: tabSpacing) {
                    ForEach(Array(split.visible.enumerated()), id: \.element) { index, key in
                        ChatTabChip(
                            key: key,
                            state: container.state(for: key),
                            isSelected: container.selectedKey == key,
                            width: widths[index],
                            onSelect: { container.select(key) },
                            onClose: { container.close(key) }
                        )
                    }
                }

                Spacer(minLength: 0)

                if hasOverflow {
                    overflowMenu(split.overflow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalInset)
        }
        .frame(height: barHeight)
        // Keep the bar a container that vends each chip as its own accessibility
        // element. Without this, SwiftUI merges a lone tab chip (which combines
        // its own children and adds an `.isButton` trait) up into the bar, so the
        // bar surfaces as a single AXButton and each chip's element — with its
        // per-tab `chat-tab-<jid>` identifier — disappears, leaving neither
        // VoiceOver (which navigates the element) nor UI automation (which
        // targets the identifier) able to address an individual tab.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-tab-bar")
    }

    private func overflowMenu(_ tabs: [ConversationKey]) -> some View {
        Menu {
            ForEach(tabs, id: \.self) { key in
                Button(overflowLabel(for: key)) {
                    container.select(key)
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityIdentifier("chat-tab-overflow")
    }

    /// Splits tabs into the visible run and the overflow remainder, keeping the
    /// selected tab visible by swapping it into the last visible slot if it would
    /// otherwise fall into the overflow menu.
    private func partition(_ tabs: [ConversationKey], visibleCount: Int) -> (visible: [ConversationKey], overflow: [ConversationKey]) {
        guard visibleCount < tabs.count else { return (tabs, []) }
        var visible = Array(tabs.prefix(visibleCount))
        var overflow = Array(tabs.suffix(from: visibleCount))
        if let selected = container.selectedKey,
           !visible.contains(selected),
           let overflowIndex = overflow.firstIndex(of: selected),
           !visible.isEmpty {
            let displaced = visible.removeLast()
            overflow.remove(at: overflowIndex)
            visible.append(selected)
            overflow.insert(displaced, at: 0)
        }
        return (visible, overflow)
    }

    // MARK: - Width math

    /// Width consumed by the gaps between `count` tabs.
    private func gaps(_ count: Int) -> CGFloat {
        CGFloat(max(0, count - 1)) * tabSpacing
    }

    /// How many tabs to show before spilling into the overflow menu: all of them
    /// while they fit at their content width OR can shrink without dropping below
    /// `minTabWidth`, otherwise as many as fit at `minTabWidth` beside the dropdown.
    private func visibleCount(available: CGFloat, intrinsics: [CGFloat]) -> Int {
        let count = intrinsics.count
        guard count > 0, available > 0 else { return count }

        let intrinsicTotal = intrinsics.reduce(0, +) + gaps(count)
        if intrinsicTotal <= available { return count }
        if (available - gaps(count)) / CGFloat(count) >= minTabWidth { return count }

        let usable = max(minTabWidth, available - controlWidth)
        let visible = max(1, Int((usable + tabSpacing) / (minTabWidth + tabSpacing)))
        return min(visible, count)
    }

    /// Assigns each visible tab a width: its full content width when the set fits
    /// the budget, otherwise short tabs keep their content width while the longer
    /// ones share the remainder equally (clamped to `minTabWidth`) — so names are
    /// shown in full whenever there is room and truncated only when crowded.
    private func distribute(_ intrinsics: [CGFloat], budget: CGFloat) -> [CGFloat] {
        guard !intrinsics.isEmpty else { return [] }
        if intrinsics.reduce(0, +) <= budget { return intrinsics }

        var widths = [CGFloat?](repeating: nil, count: intrinsics.count)
        var flexible = Array(intrinsics.indices)
        var remaining = budget
        while !flexible.isEmpty {
            let share = remaining / CGFloat(flexible.count)
            let small = flexible.filter { intrinsics[$0] <= share }
            if small.isEmpty {
                for index in flexible {
                    widths[index] = max(minTabWidth, share)
                }
                break
            }
            for index in small {
                widths[index] = intrinsics[index]
                remaining -= intrinsics[index]
            }
            flexible.removeAll { small.contains($0) }
        }
        return widths.map { $0 ?? minTabWidth }
    }

    /// The font the chip label renders in, for measuring content width.
    private static let labelFont = NSFont.preferredFont(forTextStyle: .body)

    private func intrinsicWidth(for key: ConversationKey) -> CGFloat {
        let state = container.state(for: key)
        var textWidth = ((state?.displayName ?? key.jid) as NSString)
            .size(withAttributes: [.font: Self.labelFont]).width
        // Budget the account-disambiguation label so a duplicated tab isn't sized name-only and
        // truncated. Measured in the body font (the label renders smaller), leaving a little slack.
        if let accountLabel = accountLabel(for: key) {
            textWidth += (accountLabel as NSString).size(withAttributes: [.font: Self.labelFont]).width + 4
        }
        return min(maxTabWidth, max(minTabWidth, textWidth.rounded(.up) + ChatTabChip.chrome))
    }

    /// Account-disambiguation label for a tab, via the shared `AccountIndicator.tabLabel` gate so the
    /// width math here and the rendered `ChatTabChip` always agree on what shows.
    private func accountLabel(for key: ConversationKey) -> String? {
        AccountIndicator.tabLabel(
            for: key, conversation: container.state(for: key)?.conversation,
            accountService: environment.accountService, rosterService: environment.rosterService
        )
    }

    /// Overflow-menu row title: appends the account label for a duplicated tab so the same-JID tabs
    /// stay distinguishable once they spill into the menu, matching the visible chips.
    private func overflowLabel(for key: ConversationKey) -> String {
        let name = container.state(for: key)?.displayName ?? key.jid
        guard let accountLabel = accountLabel(for: key) else { return name }
        return "\(name) — \(accountLabel)"
    }
}

private struct ChatTabChip: View {
    /// The leading slot is one fixed square whatever it shows, so a count or a typing bubble coming and going never
    /// moves the label or resizes the chip.
    private static let leadingSlotSize: CGFloat = 16
    /// With the dot centered in its slot, this puts the label as far from the dot as the dot is from the chip's edge.
    private static let slotSpacing: CGFloat = 4
    /// The presence dot sits centered in a wider leading slot. Less leading padding puts it as far from the chip's
    /// leading edge as the label is from the trailing edge.
    private static let leadingPadding: CGFloat = 4
    private static let trailingPadding: CGFloat = 8
    /// Fixed width around the label.
    static let chrome = leadingSlotSize + slotSpacing + leadingPadding + trailingPadding

    @Environment(AppEnvironment.self) private var environment
    let key: ConversationKey
    let state: ChatWindowState?
    let isSelected: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    private enum TabKind {
        case room
        case privateMessage
        case direct
    }

    private var conversation: Conversation? {
        state?.conversation
    }

    private var kind: TabKind {
        if conversation?.type == .groupchat { return .room }
        if conversation?.occupantNickname != nil { return .privateMessage }
        return .direct
    }

    private var displayName: String {
        state?.displayName ?? key.jid
    }

    private var unreadCount: Int {
        state?.unreadCount ?? 0
    }

    private var isContactTyping: Bool {
        kind == .direct && environment.chatService.isPartnerTyping(jidString: key.jid, accountID: key.accountID)
    }

    /// What the leading slot says beyond presence, for VoiceOver and automation.
    private var activityDescription: String {
        if unreadCount > 0 {
            return unreadCount == 1 ? "1 unread message" : "\(unreadCount) unread messages"
        }
        return isContactTyping ? "Typing" : ""
    }

    private var presenceDisplay: ContactPresenceDisplay {
        guard let contact = state?.contact else {
            return .unknown
        }
        return ContactPresenceDisplay.resolve(for: contact, accountID: key.accountID, presenceService: environment.presenceService)
    }

    /// The disambiguation label shown when this is a direct 1:1 whose bare JID is duplicated across
    /// accounts (MUC tabs are out of scope); nil otherwise.
    private var accountLabel: String? {
        AccountIndicator.tabLabel(
            for: key, conversation: conversation,
            accountService: environment.accountService, rosterService: environment.rosterService
        )
    }

    /// JID-only when unique; account-qualified when the JID is duplicated so the two same-JID tabs
    /// are individually addressable by automation. Single-account users keep the plain `{jid}` id.
    private var accessibilityKey: String {
        AccountIndicator.qualified(key.jid, accountID: key.accountID, qualify: accountLabel != nil, accountService: environment.accountService)
    }

    var body: some View {
        HStack(spacing: Self.slotSpacing) {
            leadingSlot
                .frame(width: Self.leadingSlotSize, height: Self.leadingSlotSize)

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let accountLabel {
                    AccountLabelText(label: accountLabel)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, Self.leadingPadding)
        .padding(.trailing, Self.trailingPadding)
        .padding(.vertical, 5)
        .frame(width: width)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .onHover { isHovered = $0 }
        .help(displayName)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(displayName)
        .accessibilityValue(activityDescription)
        .accessibilityAction { onSelect() }
        // The close button only appears on hover, so expose closing as a named action
        // for keyboard and VoiceOver users.
        .accessibilityAction(named: "Close Tab") { onClose() }
        .accessibilityIdentifier("chat-tab-\(accessibilityKey)")
    }

    /// The leading slot shows one thing: the close button while pointed at, else an unread count, else a typing bubble
    /// while the contact types, else the conversation's icon. A count outranks the bubble, since a waiting message says
    /// more than the next one being written.
    @ViewBuilder
    private var leadingSlot: some View {
        if isHovered {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("chat-tab-close-\(accessibilityKey)")
        } else if unreadCount > 0 {
            Text(unreadCount > 9 ? "9+" : "\(unreadCount)")
                .font(.caption2.weight(.semibold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .foregroundStyle(.white)
                .frame(width: Self.leadingSlotSize, height: Self.leadingSlotSize)
                .background(Circle().fill(.red))
        } else if isContactTyping {
            Image(systemName: "ellipsis.bubble.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            tabIcon
        }
    }

    @ViewBuilder
    private var tabIcon: some View {
        switch kind {
        case .room:
            Image(systemName: "number")
                .foregroundStyle(.secondary)
        case .privateMessage:
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
        case .direct:
            PresenceIndicator(display: presenceDisplay)
        }
    }
}
