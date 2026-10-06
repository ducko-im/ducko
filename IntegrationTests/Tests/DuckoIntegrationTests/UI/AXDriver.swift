import AppKit
import ApplicationServices

/// Synchronous, non-Sendable helper owned exclusively by AppAccessor's actor.
/// AX handles stay on that actor; process launch, polling and retry policy stay in the facade.
final class AXDriver {
    var pid: pid_t?

    /// Three-state outcome of `AXUIElementSetAttributeValue` classification.
    /// Distinct from `mapPerformError`'s `TestHarnessError?` shape because
    /// setter callers route the default arm to a fallback action, not to
    /// an error.
    enum SetterOutcome: Equatable {
        case done
        case error(TestHarnessError)
        case needsFallback
    }

    /// Raises the window owning `element` and makes it main/focused, so a
    /// subsequent synthetic mouse click hit-tests into it rather than an
    /// overlapping sibling window. Best-effort: failures are ignored (the
    /// caller's hit-test guard catches a still-occluded point).
    func raiseWindow(of element: AXUIElement) {
        guard let window = findAncestor(from: element, role: kAXWindowRole),
              let pid else {
            return
        }
        _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        _ = AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        _ = AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFocusedWindowAttribute as CFString,
            window
        )
    }

    /// Reads the human-visible label of a segmented-picker / tab segment.
    /// Tries `kAXTitleAttribute` then `kAXDescriptionAttribute` because
    /// SwiftUI's segmented `Picker` on macOS 26 publishes the label via
    /// description while title is `missing value`.
    func segmentLabel(of element: AXUIElement) -> String? {
        var value: AnyObject?
        var err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        if err != .success || (value as? String)?.isEmpty ?? true {
            err = AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &value)
        }
        guard err == .success else { return nil }
        return value as? String
    }

    func readValue(identifier: String) throws -> String? {
        let element = try resolveElement(identifier: identifier)
        var value: AnyObject?
        var err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if err == .attributeUnsupported || err == .noValue {
            err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        }
        if err == .success {
            return value as? String
        }
        if err == .apiDisabled {
            throw TestHarnessError.axTrustMissing
        }
        throw TestHarnessError.elementNotFound(identifier: identifier)
    }

    func collectLastIdentifier(matchingPrefix prefix: String, under identifier: String) throws -> String? {
        let container = try resolveElement(identifier: identifier)
        var matches: [String] = []
        collectIdentifiers(in: container, matchingPrefix: prefix, into: &matches)
        return matches.last
    }

    func resolveElement(identifier: String) throws -> AXUIElement {
        try resolveElement(identifier: identifier, matching: { _ in true }, qualifier: identifier)
    }

    /// Resolves the first element whose `kAXIdentifier` equals `identifier`,
    /// whose role is `role`, and — when `label` is given — whose
    /// title/description matches it. SwiftUI on macOS 26 propagates a
    /// container's `.accessibilityIdentifier` onto every leaf descendant, so
    /// several elements can share one identifier (e.g. `room-subject-view` is
    /// carried by both the topic `AXStaticText` and the pencil `AXButton`, and
    /// in edit mode by the `AXTextField` and the Save/Cancel `AXButton`s). The
    /// role — and `label` via `segmentLabel` — disambiguates which leaf to
    /// return.
    func resolveElement(identifier: String, role: String, label: String? = nil) throws -> AXUIElement {
        let qualifier = label.map { "\(identifier)[\(role):\($0)]" } ?? "\(identifier)[\(role)]"
        return try resolveElement(
            identifier: identifier,
            matching: { element in
                self.elementRole(of: element) == role && (label == nil || self.segmentLabel(of: element) == label)
            },
            qualifier: qualifier
        )
    }

    /// Shared identifier-walk: returns the first windowed descendant whose
    /// `kAXIdentifier` equals `identifier` and that also satisfies `matching`.
    /// `qualifier` is the identifier embedded in the thrown `elementNotFound`
    /// so role/label-qualified lookups report a precise diagnostic.
    func resolveElement(
        identifier: String,
        matching: (AXUIElement) -> Bool,
        qualifier: String
    ) throws -> AXUIElement {
        guard let pid else {
            throw TestHarnessError.elementNotFound(identifier: qualifier)
        }
        let appElement = AXUIElementCreateApplication(pid)
        let predicate: (AXUIElement) -> Bool = { element in
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value)
            return err == .success && (value as? String) == identifier && matching(element)
        }
        // Scope the walk to the application's windows. SwiftUI accessibility
        // identifiers we resolve always live inside windows (contacts list,
        // chat windows, attached sheets); the toolbar / menu bar / status
        // item subtrees never carry them. Walking the full
        // `AXUIElementCreateApplication` root took >12 minutes per call on
        // macOS 26 because each node forces an XPC round-trip and the menu
        // bar alone exposes thousands of items. Try the focused window
        // first to short-circuit the common case, then fall back to all
        // windows for identifiers in a non-key window.
        var focusedValue: AnyObject?
        let focusedErr = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedValue
        )
        var focusedWindow: AXUIElement?
        if focusedErr == .success, let focused = focusedValue,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            // CFGetTypeID guard above proves the cast is safe; Swift can't.
            let window = unsafeDowncast(focused, to: AXUIElement.self)
            focusedWindow = window
            if let element = findDescendant(in: window, where: predicate) {
                return element
            }
        }
        var windowsValue: AnyObject?
        let winErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        if winErr == .success, let windows = windowsValue as? [AXUIElement] {
            // Skip the focused window — we already walked it above. Each AX
            // node visit is an XPC round-trip and the menu bar alone exposes
            // thousands; walking it twice doubles the latency on a miss.
            for window in windows where window != focusedWindow {
                if let element = findDescendant(in: window, where: predicate) {
                    return element
                }
            }
        }
        // Distinguish "AX disabled" from "not found" by re-probing the root.
        var probeValue: AnyObject?
        let probe = AXUIElementCopyAttributeValue(appElement, kAXRoleAttribute as CFString, &probeValue)
        if probe == .apiDisabled {
            throw TestHarnessError.axTrustMissing
        }
        throw TestHarnessError.elementNotFound(identifier: qualifier)
    }

    func perform(action: String, on element: AXUIElement, identifier: String) throws {
        if let error = Self.mapPerformError(
            AXUIElementPerformAction(element, action as CFString),
            identifier: identifier,
            action: action
        ) {
            throw error
        }
    }

    /// Maps an `AXError` returned by `AXUIElementSetAttributeValue` to a
    /// `SetterOutcome`. Pure so the routing policy can be pinned by
    /// deterministic tests without needing a real `AXUIElement`.
    ///
    /// Routing policy:
    /// - `.success` → `.done` (caller returns).
    /// - `.apiDisabled` → `.error(.axTrustMissing)`.
    /// - `.invalidUIElement` → `.error(.elementNotFound(identifier:))`. The
    ///   handle went stale between `resolveElement` and the setter; routing
    ///   to `elementNotFound` keeps it retriable by the enclosing
    ///   `retryOnStaleElement`, preserving the stale-action-between-
    ///   resolve-and-act recovery path.
    /// - Any other `AXError` → `.needsFallback`, because that's the
    ///   SwiftUI-binding-mismatch case the keystroke synthesis path exists
    ///   for (`TextField`s that ignore `kAXSetValueAction`).
    static func mapSetterError(
        _ err: AXError,
        identifier: String
    ) -> SetterOutcome {
        switch err {
        case .success:
            .done
        case .apiDisabled:
            .error(.axTrustMissing)
        case .invalidUIElement:
            .error(.elementNotFound(identifier: identifier))
        default:
            .needsFallback
        }
    }

    /// Maps an `AXError` returned by `AXUIElementPerformAction` or by
    /// `AXUIElementSetAttributeValue` on window-focus setters
    /// (`kAXMainAttribute`, `kAXFocusedWindowAttribute`) to the project's
    /// `TestHarnessError` taxonomy. Pure so the retry-vs-fatal policy can
    /// be pinned by deterministic tests without needing a real
    /// `AXUIElement`. Returns `nil` on `.success`.
    ///
    /// Routing policy:
    /// - `.success` → `nil` (caller returns).
    /// - `.apiDisabled` → `axTrustMissing`.
    /// - `.invalidUIElement` → `elementNotFound(identifier:)`. The AX handle
    ///   was invalidated between resolve and perform (SwiftUI re-render,
    ///   NSWindow close); routing to `elementNotFound` keeps it retriable
    ///   by `retryOnStaleElement`, preserving the stale-action-between-
    ///   resolve-and-act recovery path.
    /// - Any other `AXError` → `axActionFailed(identifier:action:axError:)`,
    ///   which is NOT retried, surfacing genuine action-execution failures
    ///   (e.g. `.cannotComplete`, `.actionUnsupported`) instead of silently
    ///   retrying them as if the element handle were stale.
    static func mapPerformError(
        _ err: AXError,
        identifier: String,
        action: String
    ) -> TestHarnessError? {
        switch err {
        case .success:
            nil
        case .apiDisabled:
            .axTrustMissing
        case .invalidUIElement:
            .elementNotFound(identifier: identifier)
        default:
            .axActionFailed(identifier: identifier, action: action, axError: err.rawValue)
        }
    }

    /// Press-then-pick fallback classifier for `contextMenuItem`. `kAXPickAction`
    /// only fires when `kAXPressAction` returned non-success — `@autoclosure`
    /// keeps the pick call lazy so a successful press doesn't dispatch a
    /// second AX action.
    ///
    /// Routing policy:
    /// - press `.success` → `nil` (proceed to dismissal poll).
    /// - press `.apiDisabled` → `axTrustMissing` (fatal; pick not attempted).
    /// - press anything else → consult `pick` and route through
    ///   `mapPerformError`. `.cannotComplete` during modal menu tracking is
    ///   documented-indeterminate, so press failure is not itself fatal; the
    ///   pick result determines whether to surface `axActionFailed`.
    static func classifyContextMenuPressPick(
        press: AXError,
        pick: @autoclosure () -> AXError,
        identifier: String
    ) -> TestHarnessError? {
        switch press {
        case .success:
            return nil
        case .apiDisabled:
            return .axTrustMissing
        default:
            return mapPerformError(pick(), identifier: identifier, action: kAXPickAction)
        }
    }

    func findDescendant(
        in element: AXUIElement,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        AXTraversal.first(in: element, children: { current in
            var childrenValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenValue)
            return err == .success ? childrenValue as? [AXUIElement] : nil
        }, matching: matches)
    }

    func findDescendant(
        in element: AXUIElement,
        role: String,
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        findDescendant(in: element, where: { candidate in
            var roleValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue)
            guard err == .success, (roleValue as? String) == role else { return false }
            return matches(candidate)
        })
    }

    func findDescendant(
        in element: AXUIElement,
        roles: [String],
        where matches: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        findDescendant(in: element, where: { candidate in
            var roleValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(candidate, kAXRoleAttribute as CFString, &roleValue)
            guard err == .success, let role = roleValue as? String, roles.contains(role) else { return false }
            return matches(candidate)
        })
    }

    /// Finds the first descendant of `container` matching one of `roles` that
    /// has a `kAXStaticTextRole` descendant whose text contains `substring` —
    /// the only stable handle to a SwiftUI list row is the text it renders.
    func findDescendantRow(
        in container: AXUIElement,
        roles: [String],
        containingSubstring substring: String
    ) -> AXUIElement? {
        findDescendant(in: container, roles: roles) { row in
            self.findDescendant(in: row, role: kAXStaticTextRole, where: { element in
                self.elementText(of: element)?.contains(substring) ?? false
            }) != nil
        }
    }

    /// Finds the table-row element to right-click for the occupant whose
    /// nickname contains `substring`. SwiftUI propagates `participant-sidebar`
    /// onto inner row content, so the `AXRow`/`AXCell` that owns the
    /// `.contextMenu` is an *ancestor* of the resolved container's static text,
    /// not a descendant — a downward role search misses it. Find the nickname
    /// `AXStaticText` first, then walk up to the enclosing row, preferring the
    /// outer `AXRow` over the inner `AXCell` (the row owns the menu) and falling
    /// back to whichever of `roles` is nearest.
    func findMenuRow(
        ofTextContaining substring: String,
        in container: AXUIElement,
        roles: [String]
    ) -> AXUIElement? {
        guard let text = findDescendant(in: container, role: kAXStaticTextRole, where: { element in
            self.elementText(of: element)?.contains(substring) ?? false
        }) else {
            return nil
        }
        var fallback: AXUIElement?
        var current = text
        for _ in 0 ..< 8 {
            guard let parent = parentElement(of: current) else { break }
            if let role = elementRole(of: parent), roles.contains(role) {
                if role == kAXRowRole { return parent }
                fallback = fallback ?? parent
            }
            current = parent
        }
        return fallback
    }

    func parentElement(of element: AXUIElement) -> AXUIElement? {
        elementAttribute(element, kAXParentAttribute)
    }

    /// An attribute whose value is itself an element, like the parent or the focused window.
    func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = readAttribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        // CFGetTypeID guard above proves the cast is safe; Swift can't.
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    /// Finds the first `kAXButtonRole` descendant under any of the application's
    /// windows that satisfies `matches` — reaching a `.confirmationDialog` button
    /// that renders outside the presenting sheet. Walks windows (not the raw
    /// application root) so the menu-bar subtree's thousands of XPC-backed nodes
    /// are skipped — the same scoping `resolveElement` uses.
    func findButtonInWindows(where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        guard let pid else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var windowsValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsValue)
        guard err == .success, let windows = windowsValue as? [AXUIElement] else { return nil }
        for window in windows {
            if let match = findDescendant(in: window, role: kAXButtonRole, where: matches) {
                return match
            }
        }
        return nil
    }

    /// Reads an element's human-visible text, preferring `kAXValueAttribute`
    /// and falling back to `kAXTitleAttribute`.
    func elementText(of element: AXUIElement) -> String? {
        var value: AnyObject?
        var err = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)
        if err != .success || (value as? String) == nil {
            err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
        }
        guard err == .success else { return nil }
        return value as? String
    }

    func findAncestor(from element: AXUIElement, role: String) -> AXUIElement? {
        var current: AXUIElement = element
        while let parent = parentElement(of: current) {
            if elementRole(of: parent) == role {
                return parent
            }
            current = parent
        }
        return nil
    }

    func elementRole(of element: AXUIElement) -> String? {
        var roleValue: AnyObject?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue)
        guard err == .success else { return nil }
        return roleValue as? String
    }

    /// Finds the action element (`kAXButtonRole` or `kAXMenuItemRole`) labeled
    /// `buttonLabel` inside the top-level surface whose subtree contains
    /// `dialogText`. Skips the menu bar.
    func findDialogAction(in app: AXUIElement, dialogText: String, buttonLabel: String) -> AXUIElement? {
        guard let topChildren = readAttribute(app, kAXChildrenAttribute) as? [AXUIElement] else { return nil }
        for root in topChildren {
            if (readAttribute(root, kAXRoleAttribute) as? String) == kAXMenuBarRole { continue }
            let containsDialogText = findDescendant(in: root, role: kAXStaticTextRole) { element in
                self.elementText(of: element)?.contains(dialogText) ?? false
            } != nil
            guard containsDialogText else { continue }
            if let button = findDescendant(in: root, role: kAXButtonRole, where: { self.segmentLabel(of: $0) == buttonLabel }) {
                return button
            }
            if let item = findDescendant(in: root, role: kAXMenuItemRole, where: {
                self.segmentLabel(of: $0) == buttonLabel || self.elementText(of: $0) == buttonLabel
            }) {
                return item
            }
        }
        return nil
    }

    func findContextMenu(in app: AXUIElement) -> AXUIElement? {
        guard let topChildren = readAttribute(app, kAXChildrenAttribute) as? [AXUIElement]
        else { return nil }
        for top in topChildren {
            let topRole = readAttribute(top, kAXRoleAttribute) as? String
            if topRole == kAXMenuBarRole { continue }
            if let m = findDescendant(in: top, role: kAXMenuRole, where: { _ in true }) {
                return m
            }
        }
        return nil
    }

    func readAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return value
    }

    /// Locates the first descendant `kAXMenuItemRole` of `root` whose
    /// `kAXTitleAttribute` equals `title`. Shared between `clickMenuItem`
    /// (root = application element) and `pickPopUpItem` (root = popup's
    /// shown menu).
    func findMenuItem(in root: AXUIElement, title: String) -> AXUIElement? {
        findDescendant(in: root, role: kAXMenuItemRole, where: { element in
            var value: AnyObject?
            let err = AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value)
            return err == .success && (value as? String) == title
        })
    }

    func resolveShownMenu(for popUp: AXUIElement, identifier: String) throws -> AXUIElement {
        var shownValue: AnyObject?
        let shownErr = AXUIElementCopyAttributeValue(
            popUp,
            kAXShownMenuUIElementAttribute as CFString,
            &shownValue
        )
        if shownErr == .success,
           let shownValue,
           CFGetTypeID(shownValue) == AXUIElementGetTypeID() {
            return unsafeDowncast(shownValue, to: AXUIElement.self)
        }
        if let menu = findDescendant(in: popUp, role: kAXMenuRole, where: { _ in true }) {
            return menu
        }
        // SwiftUI `Menu` (button style) can also open its menu as a top-level
        // `AXMenu` under the application — a sibling of the windows — which the
        // popup-scoped lookups above miss. Fall back to the same app-root
        // search context menus use.
        if let pid,
           let menu = findContextMenu(in: AXUIElementCreateApplication(pid)) {
            return menu
        }
        throw TestHarnessError.elementNotFound(identifier: "\(identifier)/shown-menu")
    }

    func collectIdentifiers(
        in element: AXUIElement,
        matchingPrefix prefix: String,
        into matches: inout [String]
    ) {
        AXTraversal.postorder(in: element, children: { current in
            var childrenValue: AnyObject?
            let err = AXUIElementCopyAttributeValue(current, kAXChildrenAttribute as CFString, &childrenValue)
            return err == .success ? childrenValue as? [AXUIElement] : nil
        }, visit: { current in
            var idValue: AnyObject?
            let idErr = AXUIElementCopyAttributeValue(current, kAXIdentifierAttribute as CFString, &idValue)
            if idErr == .success, let identifier = idValue as? String, identifier.hasPrefix(prefix) {
                matches.append(identifier)
            }
        })
    }

    func elementCenter(of element: AXUIElement) -> CGPoint? {
        var posValue: AnyObject?
        var sizeValue: AnyObject?
        let posErr = AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        let sizeErr = AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard posErr == .success, sizeErr == .success,
              let posCF = posValue, let sizeCF = sizeValue,
              CFGetTypeID(posCF) == AXValueGetTypeID(),
              CFGetTypeID(sizeCF) == AXValueGetTypeID() else {
            return nil
        }
        // CFGetTypeID guards above prove the cast is safe; Swift can't.
        let posAXValue = unsafeDowncast(posCF, to: AXValue.self)
        let sizeAXValue = unsafeDowncast(sizeCF, to: AXValue.self)
        var origin = CGPoint.zero
        var size = CGSize.zero
        // AXValueGetValue returns false if the embedded AXValueType differs
        // from the requested one — guard the return so we don't dispatch a
        // click at (0, 0) on an unrelated geometry encoding.
        guard AXValueGetValue(posAXValue, .cgPoint, &origin),
              AXValueGetValue(sizeAXValue, .cgSize, &size) else {
            return nil
        }
        return CGPoint(x: origin.x + size.width / 2.0, y: origin.y + size.height / 2.0)
    }

    func postClickPair(at point: CGPoint, clickState: Int64) {
        if let down = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseDown,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            down.setIntegerValueField(.mouseEventClickState, value: clickState)
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(
            mouseEventSource: nil,
            mouseType: .leftMouseUp,
            mouseCursorPosition: point,
            mouseButton: .left
        ) {
            up.setIntegerValueField(.mouseEventClickState, value: clickState)
            up.post(tap: .cghidEventTap)
        }
    }

    /// The accessibility element the WindowServer reports as topmost at screen
    /// `point`. Used to verify a synthetic click will land in the intended
    /// window rather than an overlapping one — AX reads and `kAXPressAction`
    /// ignore occlusion, but CGEvent mouse clicks are visually hit-tested.
    func elementAtScreenPosition(_ point: CGPoint) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(system, Float(point.x), Float(point.y), &hit)
        guard err == .success else { return nil }
        return hit
    }

    /// Returns true when `point` hit-tests into the same window that owns
    /// `target` — i.e. a synthetic click there will reach `target`, not an
    /// occluding sibling window.
    func pointHitsSameWindow(as target: AXUIElement, at point: CGPoint) -> Bool {
        guard let targetWindow = findAncestor(from: target, role: kAXWindowRole),
              let hit = elementAtScreenPosition(point),
              let hitWindow = findAncestor(from: hit, role: kAXWindowRole)
        else {
            return false
        }
        return hitWindow == targetWindow
    }
}
