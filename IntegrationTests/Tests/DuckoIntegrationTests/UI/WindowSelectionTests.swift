import Testing

/// Pins the exact-before-substring window-title selection in
/// `AppAccessor.windowIndex`. Without this pure seam, a regression that flips
/// the preference back to first-substring-wins would only surface as live UI
/// test flake. Top-level `enum` to opt out of the parent suite's
/// `.enabled(if:)` credentials trait.
enum WindowSelectionTests {
    struct Selection {
        @Test func `exact title match beats an earlier substring match`() {
            #expect(AppAccessor.windowIndex(matching: "Chat", titles: ["Chat History", "Chat"]) == 1)
        }

        @Test func `an exact-only title resolves to its index`() {
            #expect(AppAccessor.windowIndex(matching: "Contacts", titles: ["Contacts"]) == 0)
        }

        @Test func `a substring match is used when no title matches exactly`() {
            #expect(AppAccessor.windowIndex(matching: "Chat", titles: ["Chat History"]) == 0)
        }

        @Test func `no matching title returns nil`() {
            #expect(AppAccessor.windowIndex(matching: "Chat", titles: ["Welcome", "Contacts"]) == nil)
        }

        @Test func `an exact match beats a later substring match`() {
            #expect(AppAccessor.windowIndex(matching: "Chat", titles: ["Chat", "Chat History"]) == 0)
        }

        @Test func `a substring fallback returns the first matching title`() {
            #expect(AppAccessor.windowIndex(matching: "Chat", titles: ["Chat History", "Chat Log"]) == 0)
        }
    }
}
