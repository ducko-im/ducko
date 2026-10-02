---
name: swiftui
description: Write, review, or improve SwiftUI code across state management, view composition, performance, modern APIs, navigation, animation, accessibility, Liquid Glass (iOS 26+), and design principles. Use when building new SwiftUI features, refactoring existing views, reviewing code quality, designing tab/navigation architecture, adopting Liquid Glass, debugging performance/layout issues, or applying Apple Human Interface Guidelines.
license: MIT
---

Write and review SwiftUI code for correctness, modern API usage, state-flow correctness, performance, accessibility, and adherence to Apple's Human Interface Guidelines. Report only genuine problems — do not nitpick or invent issues.


## Review process

1. Check for deprecated API using [references/api.md](references/api.md) and [references/modern-apis.md](references/modern-apis.md).
2. Check that views, modifiers, and animations have been written optimally using [references/views.md](references/views.md), [references/view-structure.md](references/view-structure.md), [references/animation-basics.md](references/animation-basics.md), [references/animation-transitions.md](references/animation-transitions.md), and [references/animation-advanced.md](references/animation-advanced.md).
3. Validate state management and data flow using [references/data.md](references/data.md) and [references/state-management.md](references/state-management.md).
4. Ensure navigation is updated and performant using [references/navigation.md](references/navigation.md) and [references/sheet-navigation-patterns.md](references/sheet-navigation-patterns.md).
5. Validate list behavior using [references/list-patterns.md](references/list-patterns.md).
6. Validate scroll behavior using [references/scroll-patterns.md](references/scroll-patterns.md).
7. Validate text formatting using [references/text-formatting.md](references/text-formatting.md).
8. Validate image handling using [references/image-optimization.md](references/image-optimization.md).
9. Ensure the code uses designs that are accessible and compliant with Apple's Human Interface Guidelines using [references/design.md](references/design.md) and [references/design-principles.md](references/design-principles.md).
10. Validate accessibility compliance (Dynamic Type, VoiceOver, Reduce Motion) using [references/accessibility.md](references/accessibility.md).
11. Ensure the code runs efficiently using [references/performance.md](references/performance.md) and [references/performance-patterns.md](references/performance-patterns.md).
12. Check layout best practices using [references/layout-best-practices.md](references/layout-best-practices.md).
13. For view-file refactoring (ordering, extracting sections, MV pattern), use [references/mv-patterns.md](references/mv-patterns.md).
14. If adopting Liquid Glass (iOS 26+), use [references/liquid-glass.md](references/liquid-glass.md).
15. For component-specific patterns (TabView, NavigationStack, sheets, forms, grids, menus, split views, theming, etc.), use the files under `references/components/`. Start with [references/components/components-index.md](references/components/components-index.md).
16. For macOS apps, validate scenes, window/toolbar styling, and macOS-specific views/AppKit interop using [references/macos-scenes.md](references/macos-scenes.md), [references/macos-window-styling.md](references/macos-window-styling.md), and [references/macos-views.md](references/macos-views.md).
17. Validate localization of user-facing text using [references/localization.md](references/localization.md) — Ducko's SwiftUI views live in the `DuckoUI` library target, whose resources live in `Bundle.module`, so once localization exists every user-facing string in a library target must pin the bundle (`Text("…", bundle: #bundle)` / `String(localized:bundle:)`); the bare overloads silently miss the catalog. Only `DuckoApp` (the executable) uses the main bundle.
18. Validate focus handling (`@FocusState`, `@FocusedValue` command wiring, focusable interactions, focus scope) using [references/focus-patterns.md](references/focus-patterns.md).
19. Quick validation of Swift code using [references/swift.md](references/swift.md).
20. Final code hygiene check using [references/hygiene.md](references/hygiene.md).

If doing a partial review, load only the relevant reference files.


## Core Instructions

- iOS 26 exists and is the default deployment target for new apps.
- Target Swift 6.2 or later, using modern Swift concurrency.
- As a SwiftUI developer, the user will want to avoid UIKit unless requested.
- Do not introduce third-party frameworks without asking first.
- Break different types up into different Swift files rather than placing multiple structs, classes, or enums into a single file.
- Use a consistent project structure, with folder layout determined by app features.


## Quick start (new SwiftUI view)

1. Define the view's state and its ownership location (`@State`, `@Binding`, `@Environment`, injected `@Observable`, etc.).
2. Identify dependencies to inject via `@Environment`.
3. Sketch the view hierarchy and extract repeated parts into subviews early.
4. Implement async loading with `.task` and explicit loading/error states.
5. Add accessibility labels or identifiers when the UI is interactive.
6. Validate with a build and update callsites if needed.


## View file structure (refactor/review guidance)

When laying out or reviewing a SwiftUI view file, prefer this top-to-bottom order:

1. `@Environment`
2. `private` / `public` `let`
3. `@State` / other stored properties
4. computed `var` (non-view)
5. `init`
6. `body`
7. computed view builders / other view helpers
8. helper / async functions

### Prefer Model-View (MV) patterns by default

- Views are lightweight state expressions; models/services own business logic.
- Favor `@State`, `@Environment`, `@Query`, `.task`, and `.onChange` for orchestration.
- Inject services and shared models via `@Environment`; keep views small and composable.
- Split large views into subviews rather than introducing a view model.
- If a view model already exists, make it non-optional when possible and initialize it in the view's `init`. Avoid `bootstrapIfNeeded` patterns.

See [references/mv-patterns.md](references/mv-patterns.md) for the rationale.

### Keep a stable view tree

Avoid returning completely different root branches from `body` or a computed view via `if/else`. Prefer a single stable base view and place conditions inside sections/modifiers (`overlay`, `opacity`, `disabled`, `toolbar`, row content). Top-level branch swapping causes identity churn and broader invalidation.

```swift
// Prefer
var body: some View {
    List { documentsListContent }
        .toolbar { if canEdit { editToolbar } }
}

// Avoid
var documentsListView: some View {
    if canEdit { editableDocumentsList } else { readOnlyDocumentsList }
}
```

### Split large bodies (>~300 lines)

When a SwiftUI view file grows past ~300 lines, split it using `private` extensions grouped with `// MARK: - Actions`, `// MARK: - Subviews`, `// MARK: - Helpers`, etc. Keep the main `struct` focused on stored properties, `init`, and `body`.


## State management

- **Always prefer `@Observable` over `ObservableObject`** for new code.
- **Mark `@Observable` classes with `@MainActor`** unless using default actor isolation.
- **Always mark `@State` and `@StateObject` as `private`.**
- **Never declare passed values as `@State` or `@StateObject`** — they only accept initial values.
- Use `@State` with `@Observable` classes (not `@StateObject`).
- `@Binding` only when a child needs to **modify** parent state.
- `@Bindable` for injected `@Observable` objects that need bindings.
- Use `let` for read-only values; `var` + `.onChange()` for reactive reads.
- Legacy: `@StateObject` for owned `ObservableObject`; `@ObservedObject` for injected.
- Nested `ObservableObject` doesn't observe properly — pass nested objects directly; `@Observable` handles nesting fine.

### Property wrapper selection (modern)

| Wrapper | Use when |
|---------|----------|
| `@State` | Internal view state (must be `private`), or owned `@Observable` class |
| `@Binding` | Child modifies parent's state |
| `@Bindable` | Injected `@Observable` needing bindings |
| `let` | Read-only value from parent |
| `var` | Read-only value watched via `.onChange()` |


## Modern API quick reference

| Deprecated | Modern alternative |
|------------|-------------------|
| `foregroundColor()` | `foregroundStyle()` |
| `cornerRadius()` | `clipShape(.rect(cornerRadius:))` |
| `tabItem()` | `Tab` API |
| `onTapGesture()` | `Button` (unless need location/count) |
| `NavigationView` | `NavigationStack` |
| `onChange(of:) { value in }` | `onChange(of:) { old, new in }` or `onChange(of:) { }` |
| `fontWeight(.bold)` | `bold()` |
| `GeometryReader` | `containerRelativeFrame()` or `visualEffect()` |
| `showsIndicators: false` | `.scrollIndicators(.hidden)` |
| `String(format: "%.2f", value)` | `Text(value, format: .number.precision(.fractionLength(2)))` |
| `string.contains(search)` | `string.localizedStandardContains(search)` (for user input) |

Details: [references/modern-apis.md](references/modern-apis.md).


## Performance rules

- Pass only needed values to views — avoid large "config" or "context" objects.
- Eliminate unnecessary dependencies to reduce update fan-out.
- Check for value changes before assigning state in hot paths.
- Avoid redundant state updates in `onReceive`, `onChange`, scroll handlers.
- Use `LazyVStack` / `LazyHStack` for large lists.
- Use stable identity for `ForEach` (never `.indices` for dynamic content).
- Ensure a constant number of views per `ForEach` element.
- Avoid inline filtering in `ForEach` — prefilter and cache.
- Avoid `AnyView` in list rows.
- Avoid `GeometryReader` when alternatives exist (`containerRelativeFrame()`, `visualEffect()`).
- Gate frequent geometry updates by thresholds.
- Use `Self._printChanges()` to debug unexpected view updates.

Details: [references/performance.md](references/performance.md), [references/performance-patterns.md](references/performance-patterns.md).


## Animation rules

- Use `.animation(_:value:)` with value parameter (the version without value is deprecated — too broad).
- Use `withAnimation` for event-driven animations (button taps, gestures).
- Prefer transforms (`offset`, `scale`, `rotation`) over layout changes (`frame`) for performance.
- Transitions require animations **outside** the conditional structure.
- Custom `Animatable` implementations must have explicit `animatableData`.
- Use `.phaseAnimator` for multi-step sequences (iOS 17+).
- Use `.keyframeAnimator` for precise timing control (iOS 17+).
- Animation completion handlers need `.transaction(value:)` for re-execution.
- Implicit animations override explicit animations (later in view tree wins).

Details: [references/animation-basics.md](references/animation-basics.md), [references/animation-transitions.md](references/animation-transitions.md), [references/animation-advanced.md](references/animation-advanced.md).


## Component patterns (TabView, NavigationStack, sheets, etc.)

For component-specific patterns (TabView architecture, NavigationStack routing, sheet ownership, forms, grids, split views, menus, theming, matched transitions, etc.), read [references/components/components-index.md](references/components/components-index.md) first, then load the specific component reference.

### Sheet patterns (commonly asked)

Prefer `.sheet(item:)` over `.sheet(isPresented:)` when state represents a selected model. Avoid `if let` inside a sheet body. Sheets should own their actions and call `dismiss()` internally rather than forwarding `onCancel`/`onConfirm` closures.

```swift
@State private var selectedItem: Item?

.sheet(item: $selectedItem) { item in
    EditItemSheet(item: item)
}

struct EditItemSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Store.self) private var store
    let item: Item
    @State private var isSaving = false

    var body: some View {
        Button(isSaving ? "Saving…" : "Save") {
            Task { await save() }
        }
    }

    private func save() async {
        isSaving = true
        await store.save(item)
        dismiss()
    }
}
```


## Liquid Glass (iOS 26+)

**Only adopt when explicitly requested.** When adopting:

- Use native `glassEffect`, `GlassEffectContainer`, and glass button styles.
- Wrap multiple glass elements in `GlassEffectContainer`.
- Apply `.glassEffect()` after layout and visual modifiers.
- Use `.interactive()` only for tappable or focusable elements.
- Use `glassEffectID` with `@Namespace` for morphing transitions.
- Gate with `#available(iOS 26, *)` and provide a non-glass fallback.

```swift
if #available(iOS 26, *) {
    content
        .padding()
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
} else {
    content
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
}
```

Full reference: [references/liquid-glass.md](references/liquid-glass.md).


## Design principles quick check

[references/design-principles.md](references/design-principles.md) contains a long-form guide to spacing grids, typography, semantic colors, and widget patterns. Quick checks when reviewing a screen:

- Is spacing on a consistent grid (typically 4 or 8 pt)?
- Are typography styles system text styles (`.body`, `.headline`, ...) rather than raw pixel sizes?
- Are colors semantic (`Color(.label)`, `.accentColor`, `.tint(...)`) rather than hard-coded RGB?
- Do widgets follow Apple's containerBackground + padding conventions?
- Is the layout adaptive (works at max Dynamic Type, in both light and dark mode)?


## Output Format

Organize findings by file. For each issue:

1. State the file and relevant line(s).
2. Name the rule being violated (e.g., "Use `foregroundStyle()` instead of `foregroundColor()`").
3. Show a brief before/after code fix.

Skip files with no issues. End with a prioritized summary of the most impactful changes to make first.

Example output:

### ContentView.swift

**Line 12: Use `foregroundStyle()` instead of `foregroundColor()`.**

```swift
// Before
Text("Hello").foregroundColor(.red)

// After
Text("Hello").foregroundStyle(.red)
```

**Line 24: Icon-only button is bad for VoiceOver - add a text label.**

```swift
// Before
Button(action: addUser) {
    Image(systemName: "plus")
}

// After
Button("Add User", systemImage: "plus", action: addUser)
```

**Line 31: Avoid `Binding(get:set:)` in view body - use `@State` with `onChange()` instead.**

```swift
// Before
TextField("Username", text: Binding(
    get: { model.username },
    set: { model.username = $0; model.save() }
))

// After
TextField("Username", text: $model.username)
    .onChange(of: model.username) {
        model.save()
    }
```

### Summary

1. **Accessibility (high):** The add button on line 24 is invisible to VoiceOver.
2. **Deprecated API (medium):** `foregroundColor()` on line 12 should be `foregroundStyle()`.
3. **Data flow (medium):** The manual binding on line 31 is fragile and harder to maintain.

End of example.


## References

### Core review (Hudson base)

- [references/api.md](references/api.md) — updating code for modern API, and the deprecated code it replaces.
- [references/views.md](references/views.md) — view structure, composition, and animation.
- [references/data.md](references/data.md) — data flow, shared state, and property wrappers.
- [references/navigation.md](references/navigation.md) — navigation using `NavigationStack`/`NavigationSplitView`, plus alerts, confirmation dialogs, and sheets.
- [references/design.md](references/design.md) — guidance for building accessible apps that meet Apple's Human Interface Guidelines.
- [references/accessibility.md](references/accessibility.md) — Dynamic Type, VoiceOver, Reduce Motion, and other accessibility requirements.
- [references/performance.md](references/performance.md) — optimizing SwiftUI code for maximum performance.
- [references/swift.md](references/swift.md) — tips on writing modern Swift code, including using Swift Concurrency effectively.
- [references/hygiene.md](references/hygiene.md) — making code compile cleanly and be maintainable long-term.

### State, composition, layout

- [references/state-management.md](references/state-management.md) — property wrappers and data flow (prefer `@Observable`), `Equatable` setter short-circuit, dependency granularity, `@Entry` hygiene.
- [references/view-structure.md](references/view-structure.md) — view composition, extraction, and container patterns.
- [references/layout-best-practices.md](references/layout-best-practices.md) — layout patterns, context-agnostic views, testability.
- [references/mv-patterns.md](references/mv-patterns.md) — Model-View rationale and patterns for view-file refactors.
- [references/focus-patterns.md](references/focus-patterns.md) — the full focus system: `@FocusState`, `@FocusedValue`/`@Entry` command wiring, `.focusable(interactions:)`, focus scope/sections, `.searchFocused`, pitfalls including Return-key handling in a send-on-Return field.

### Modern APIs

- [references/modern-apis.md](references/modern-apis.md) — modern API usage and deprecated replacements.
- [references/text-formatting.md](references/text-formatting.md) — modern text formatting and string operations.
- [references/localization.md](references/localization.md) — localizing user-facing text, String Catalogs, `bundle: #bundle` for package targets, `LocalizedStringResource`.

### Lists, scrolling, sheets, navigation patterns

- [references/list-patterns.md](references/list-patterns.md) — `ForEach` identity, stability, unary rows (`-LogForEachSlowPath`), list best practices.
- [references/scroll-patterns.md](references/scroll-patterns.md) — `ScrollView` patterns and programmatic scrolling.
- [references/sheet-navigation-patterns.md](references/sheet-navigation-patterns.md) — sheet presentation and navigation patterns.

### Performance

- [references/performance-patterns.md](references/performance-patterns.md) — performance optimization techniques and anti-patterns.
- [references/image-optimization.md](references/image-optimization.md) — `AsyncImage`, image downsampling, optimization.

### Animations

- [references/animation-basics.md](references/animation-basics.md) — core animation concepts, implicit/explicit animations, timing, performance.
- [references/animation-transitions.md](references/animation-transitions.md) — transitions, custom transitions, `Animatable` protocol.
- [references/animation-advanced.md](references/animation-advanced.md) — transactions, phase/keyframe animations (iOS 17+), completion handlers.

### Liquid Glass & design

- [references/liquid-glass.md](references/liquid-glass.md) — iOS 26+ Liquid Glass API, morphing, fallbacks, examples.
- [references/design-principles.md](references/design-principles.md) — long-form guide to spacing grids, typography, semantic colors, widget patterns (from arjitj2/swiftui-design-principles).

### macOS

- [references/macos-scenes.md](references/macos-scenes.md) — scene types: `WindowGroup`, `Window`, `UtilityWindow`, `Settings`, `MenuBarExtra`, `DocumentGroup`, `openWindow`.
- [references/macos-window-styling.md](references/macos-window-styling.md) — window/toolbar styles, `windowResizability`, `defaultSize`/`defaultPosition`, `Inspector`, `CommandGroup`, keyboard shortcuts.
- [references/macos-views.md](references/macos-views.md) — `Table`, `HSplitView`/`VSplitView`, `fileImporter`/`fileExporter` (security-scoped access), cross-app drag & drop, custom-UTI `onCopyCommand` and `DragGesture` cancellation traps, `NSViewRepresentable` + Coordinator.

### Component patterns (`references/components/`)

- [references/components/components-index.md](references/components/components-index.md) — index and entry point for component patterns.
- [references/components/app-wiring.md](references/components/app-wiring.md) — TabView + NavigationStack + sheets app scaffolding.
- [references/components/tabview.md](references/components/tabview.md) — `TabView` architecture and patterns.
- [references/components/navigationstack.md](references/components/navigationstack.md) — `NavigationStack` routing.
- [references/components/split-views.md](references/components/split-views.md) — `NavigationSplitView` patterns.
- [references/components/sheets.md](references/components/sheets.md) — sheet ownership, item-driven sheets.
- [references/components/overlay.md](references/components/overlay.md) — overlay patterns.
- [references/components/form.md](references/components/form.md) — form layout patterns.
- [references/components/list.md](references/components/list.md) — list patterns and cell reuse.
- [references/components/grids.md](references/components/grids.md) — grid layouts.
- [references/components/scrollview.md](references/components/scrollview.md) — scroll view patterns.
- [references/components/searchable.md](references/components/searchable.md) — `.searchable` patterns.
- [references/components/controls.md](references/components/controls.md) — control component patterns.
- [references/components/input-toolbar.md](references/components/input-toolbar.md) — keyboard/input toolbar patterns.
- [references/components/focus.md](references/components/focus.md) — focus management.
- [references/components/deeplinks.md](references/components/deeplinks.md) — deep-link handling.
- [references/components/haptics.md](references/components/haptics.md) — haptic feedback.
- [references/components/loading-placeholders.md](references/components/loading-placeholders.md) — loading and placeholder patterns.
- [references/components/lightweight-clients.md](references/components/lightweight-clients.md) — lightweight networking clients.
- [references/components/macos-settings.md](references/components/macos-settings.md) — macOS Settings scene patterns.
- [references/components/matched-transitions.md](references/components/matched-transitions.md) — matched geometry transitions.
- [references/components/media.md](references/components/media.md) — media playback components.
- [references/components/menu-bar.md](references/components/menu-bar.md) — macOS menu bar components.
- [references/components/theming.md](references/components/theming.md) — theming and appearance.
- [references/components/title-menus.md](references/components/title-menus.md) — title bar menus.
- [references/components/top-bar.md](references/components/top-bar.md) — top bar patterns.
- [references/components/async-state.md](references/components/async-state.md) — `.task`/`.task(id:)`, cancellation, and debounced async state.
- [references/components/previews.md](references/components/previews.md) — `#Preview` coverage, fixtures, and injected mock dependencies.
- [references/components/scroll-reveal.md](references/components/scroll-reveal.md) — scroll-driven reveal of secondary detail surfaces.


## Philosophy

- Focus on **facts and best practices** — no architectural opinion wars.
- Encourage separating business logic for testability without enforcing MVVM/VIPER/TCA.
- Prefer modern APIs over deprecated ones.
- Thread safety with `@MainActor` and `@Observable`.
- Optimize for performance and maintainability.
- Follow Apple's Human Interface Guidelines and API design patterns.
