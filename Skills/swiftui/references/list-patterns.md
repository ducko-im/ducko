# SwiftUI List Patterns Reference

## ForEach Identity and Stability

**Always provide stable identity for `ForEach`.** Never use `.indices` for dynamic content.

```swift
// Good - stable identity via Identifiable
extension User: Identifiable {
    var id: String { userId }
}

ForEach(users) { user in
    UserRow(user: user)
}

// Good - stable identity via keypath
ForEach(users, id: \.userId) { user in
    UserRow(user: user)
}

// Wrong - indices create static content
ForEach(users.indices, id: \.self) { index in
    UserRow(user: users[index])  // Can crash on removal!
}

// Wrong - unstable identity
ForEach(users, id: \.self) { user in
    UserRow(user: user)  // Only works if User is Hashable and stable
}
```

**Critical**: Ensure **constant number of views per element** in `ForEach`:

```swift
// Good - consistent view count
ForEach(items) { item in
    ItemRow(item: item)
}

// Bad - variable view count breaks identity
ForEach(items) { item in
    if item.isSpecial {
        SpecialRow(item: item)
        DetailRow(item: item)
    } else {
        RegularRow(item: item)
    }
}
```

**Avoid inline filtering:**

```swift
// Bad - unstable identity, changes on every update
ForEach(items.filter { $0.isEnabled }) { item in
    ItemRow(item: item)
}

// Good - prefilter and cache
@State private var enabledItems: [Item] = []

var body: some View {
    ForEach(enabledItems) { item in
        ItemRow(item: item)
    }
    .onChange(of: items) { _, newItems in
        enabledItems = newItems.filter { $0.isEnabled }
    }
}
```

**Avoid `AnyView` in list rows:**

```swift
// Bad - hides identity, increases cost
ForEach(items) { item in
    AnyView(item.isSpecial ? SpecialRow(item: item) : RegularRow(item: item))
}

// Good - Create a unified row view with a single top-level container
ForEach(items) { item in
    ItemRow(item: item)
}

struct ItemRow: View {
    let item: Item

    var body: some View {
        // The VStack keeps the row "unary" (one top-level view) so the
        // List can template row ids without evaluating every row's body.
        VStack {
            if item.isSpecial {
                SpecialRow(item: item)
            } else {
                RegularRow(item: item)
            }
        }
    }
}
```

**Why**: Stable identity is critical for performance and animations. Unstable identity causes excessive diffing, broken animations, and potential crashes.

### Prefer unary rows in `List`

`List` needs the identity of every row up front. When each row's body produces a **single top-level view** (a "unary" row), SwiftUI templates the row id from the `ForEach` element's id alone, without running each row's `body`. When the body branches between different top-level shapes — a bare top-level `switch`, a top-level `if`/`else` or `if` without `else`, or an `AnyView` — structural identity varies per row, so SwiftUI falls back to evaluating every row's body just to compute ids. That cost scales with the number of rows.

Wrap branching content in any single-root container (`VStack`, `HStack`, `ZStack`, or a custom wrapper) so the row is always exactly one top-level view, as `ItemRow` above does. A top-level `if` without an `else` is also "multi" (0 or 1 views); if some elements shouldn't be rows at all, filter the collection before it reaches the `ForEach` rather than producing a zero-view row.

To find non-constant row builders in an existing app, launch with `-LogForEachSlowPath YES`; SwiftUI logs each `ForEach` inside a lazy container whose row body produces a non-constant number of views.

## Enumerated Sequences

On Swift 6.2 (Ducko targets macOS 26), `enumerated()` conforms to `Collection` (SE-0459), so it works directly in a `ForEach` — no `Array(...)` wrapper needed.

```swift
// Correct - direct, keyed on the element's own identity
ForEach(items.enumerated(), id: \.element.id) { index, item in
    Text("\(index): \(item.name)")
}
```

Key the row on the **element's** identity, not its position. `id: \.offset` makes the index the identity, so inserts and reorders reset row state and break animations — the same anti-pattern as `\.self` on `items.indices`. (`\.offset` is only safe for a static list that never changes.)

## List with Custom Styling

```swift
// Remove default background and separators
List(items) { item in
    ItemRow(item: item)
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowSeparator(.hidden)
}
.listStyle(.plain)
.scrollContentBackground(.hidden)
.background(Color.customBackground)
.environment(\.defaultMinListRowHeight, 1)  // Allows custom row heights
```

## List with Pull-to-Refresh

```swift
List(items) { item in
    ItemRow(item: item)
}
.refreshable {
    await loadItems()
}
```

## List Selection & Double-Click (macOS)

For single-click select + double-click open, use native selection plus `contextMenu`'s `primaryAction` — **never** a row tap gesture.

```swift
List(selection: $selection) {
    ForEach(items) { item in
        ItemRow(item: item)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // whole row hit-testable for selection
            .tag(item.id)
    }
}
.contextMenu(forSelectionType: Item.ID.self) { _ in
    // per-selection menu (may be empty; per-row .contextMenu still works)
} primaryAction: { ids in
    if let id = ids.first { open(id) }   // fires on double-click AND Return
}
```

- **Do not** attach `.onTapGesture(count:)` or `.simultaneousGesture(TapGesture())` to a row for double-click. The gesture owns the row's hit-tested content area (its `.contentShape`) and wins the gesture arena there, so `List` never sees single clicks in the content — **only the `listRowInsets` margins (no content/gesture) still select**. Symptom: "edges select, center doesn't; double-click works everywhere." `primaryAction` avoids this because it installs no row gesture.
- A plain `Button` row selects reliably but **can't deselect** (it only ever *sets* selection) — wrong for list semantics. Use `List(selection:)`, not buttons.
- Exclude headers/section rows from selection with `.selectionDisabled()`.
- A `DisclosureGroup` label that carries a `.tag` is selectable in a sidebar list, also when its expansion is bound with `DisclosureGroup(isExpanded:)`.
- Requires macOS 13+ (`forSelectionType`); `.selectionDisabled()` is macOS 14+.

## Keyboard Focus After a Click (macOS)

A `List(selection:)` does not take keyboard focus when a row is clicked (observed on macOS 27): the window stays first responder, so the arrow keys do nothing. A sidebar list and a list in a detail pane behave alike, with a `@State` binding or a custom one.

Give the list a focus state and set it on every click:

```swift
@FocusState private var isFocused: Bool

List(selection: $selection) {
    // rows
}
.focused($isFocused)
.simultaneousGesture(TapGesture().onEnded { isFocused = true })
```

- Attach the gesture to the `List`. There it fires on every click and selection keeps working; on a row it breaks selection, as described above.
- `.onTapGesture` on the `List` never fires, and `.focusable()` alone changes nothing.
- Setting the focus state from `onChange(of: selection)` misses a click on the already-selected row, which does not call the selection binding's setter. It also moves keyboard focus on a selection made from code.
- This is not the redundant write that [focus-patterns.md](focus-patterns.md) warns about. That pitfall concerns a view that takes focus on a click through `.focusable()`, which a `List` does not. Repeated taps on a list that already had focus left its focus state set.
- That the arrow keys move the selection after a tap sets the focus state is unconfirmed. They did so when the focus state was set from a selection change, and a tap sets the same state. A `primaryAction` double-click on a list that has this gesture is untried. Confirm both in the running app.

## Selection Painting in a Sidebar List (macOS)

A `List(selection:)` in a `NavigationSplitView` sidebar paints its selection wrongly when the selected row leaves or returns to the list, and when the list is built with a row already selected (observed on macOS 27, with rows in `DisclosureGroup` sections that a filter can hide):

- When the selected row is removed, the list keeps it painted where it was. The accessibility tree holds no row there, and a selection binding that reads `nil` changes nothing.
- When the row comes back together with its section, it shows unselected although the binding still names it.
- A list built with a row of a later section already selected keeps that row highlighted after another row is selected.

Give the list a new identity whenever a change alters whether the selected row is listed, and hand a rebuilt list its selection after it is built:

```swift
@State private var selectedListGeneration = 0

List(selection: Binding(
    get: { selectedListGeneration == model.listGeneration ? model.selection : nil },
    set: { model.select($0) }
)) {
    // sections and rows
}
.id(model.listGeneration)
.task(id: model.listGeneration) {
    selectedListGeneration = model.listGeneration
}
```

- Count the generation in the model, at the change that hides or returns the selected row. A generation derived in the view also rebuilds on a click, which resets the scroll position.
- The closure binding is deliberate. Its getter depends on view state, which no projected binding can express.
- The first list reads the selection at once, which is right when it is built before anything is selected. Start the view's counter one behind the model's when a selection can already stand.
- Hiding and showing the sidebar needs no rebuild.
- Check the result in a window capture. The accessibility tree reports the right selection throughout.
- `TranscriptSidebarView` with `TranscriptViewerState.sidebarListGeneration` is the worked example.

## Sizing a Window to List Content (macOS)

`.windowResizability(.contentSize)` fits a window to its content — but a `List` is **greedy in both axes and reports no intrinsic content size**, so the window won't shrink to fit it. Drive the size explicitly:

- **Height**: give the `List` a `.frame(height:)` computed from visible row count × measured row heights, capped at screen height (so a long list scrolls instead of overflowing).
- **Width**: a `List` never reports the widest row, so measure it yourself (e.g. render the labels off-screen with `.fixedSize()` and a max-reducing `PreferenceKey`) and set the content's width.

Two measurement gotchas:

- `.plain` reserves its **own** per-row horizontal padding (~8pt leading, ~9pt trailing — trailing leaves room for the scroller) **on top of** your `listRowInsets`; compensate when aligning row content to a header outside the list.
- A `List` row renders its text **noticeably wider** (~14pt for a ~20-char label) than an identical off-screen `Text` with the same modifiers, so off-screen measurement under-reports row width — add an offset. `.accessibilityElement(children: .combine)` on a row also hides the inner label, so AX can't expose its width directly.

## Animating List Resize (macOS)

A `List` does **not** animate size + content changes cleanly. `.frame(height: computedHeight).animation(.smooth, value: computedHeight)` animates the container's height while the rows pop in/out (jumpy on insert/remove); keying the animation on the data triggers (search text, expansion state) instead of a derived height is better but still not smooth. Separately, a **window-level** frame `.animation(value: width/height)` animates every static sibling in that view tree too (e.g. a header's avatar slides as the window reflows) — scope animation to only the changing subtree. For an auto-sizing list (e.g. an Adium-style buddy list), snapping (no animation) is the safe default; a smooth resize needs coordinated row-transition + frame animation, or an AppKit-level window-frame animation.

## Summary Checklist

- [ ] ForEach uses stable identity (never `.indices` for dynamic content)
- [ ] Constant number of views per ForEach element
- [ ] No inline filtering in ForEach (prefilter and cache instead)
- [ ] No `AnyView` in list rows
- [ ] Don't convert enumerated sequences to arrays
- [ ] Use `.refreshable` for pull-to-refresh
- [ ] Custom list styling uses appropriate modifiers
