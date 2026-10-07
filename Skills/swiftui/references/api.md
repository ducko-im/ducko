# Using modern SwiftUI API

Many older SwiftUI declarations are soft-deprecated, so Xcode stays quiet about them and a warning-free build does not establish that the code uses current API. See [Handling soft-deprecated APIs](#handling-soft-deprecated-apis) below for what that means and when to raise it.

Also check the Dynamic Type deprecations in [accessibility.md](accessibility.md) and the animatable modifier deprecations in [views.md](views.md).

- Always use `foregroundStyle()` instead of `foregroundColor()`.
- Replace soft-deprecated `accentColor()` with `tint()`. Configure the asset catalog's accent color for an app-wide default. The `Color.accentColor` value itself is current.
- Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.
- Always use the `Tab` API instead of `tabItem()`.
- Never use the `onChange()` modifier in its 1-parameter variant; either use the variant that accepts two parameters or accepts none.
- For sizing and positioning, prefer `containerRelativeFrame()`, `visualEffect()`, or the `Layout` protocol to `GeometryReader` when they can do the job. To keep content clear of safe areas, rely on SwiftUI's default insets rather than measuring them. Pin real bar content with `safeAreaInset()` or `safeAreaBar()` (macOS 26+), which reserve space as well as placing it, and use `safeAreaPadding()` only for intentional extra spacing inside the safe area.
- Use `toolbarVisibility()` in place of `toolbar(_:for:)` with a visibility, and `toolbarBackgroundVisibility()` in place of the visibility overload of `toolbarBackground(_:for:)`. The older names became soft-deprecated with the macOS 15 renames. For example, `.toolbarVisibility(.hidden, for: .windowToolbar)`. Keep `toolbarBackground()` when it supplies a background style.
- Replace soft-deprecated `colorScheme()` with an environment override, such as `.environment(\.colorScheme, .light)`. Despite Apple's rename annotation, `preferredColorScheme()` is not equivalent: it affects the entire window or sheet, whereas the environment override preserves the original view-and-descendants scope.
- Prefer `autocorrectionDisabled()` to the soft-deprecated `disableAutocorrection()`.
- Define a named coordinate space with `.coordinateSpace(.named("canvas"))`, replacing soft-deprecated `coordinateSpace(name:)`. Lookups still use `frame(in: .named("canvas"))`.
- Obtain color components with `color.resolve(in:)`, passing the relevant environment. It resolves red, green, blue, and opacity correctly for appearances such as light and dark mode without AppKit. Avoid soft-deprecated `Color.cgColor`, which returns `nil` for dynamic colors, including asset colors.
- With Xcode 27+, use `@ContentBuilder` for newly written view builders. SwiftUI now uses this name throughout most of its declarations; `@ViewBuilder` names the same type, so existing uses need no change and are not findings. This is a compiler/SDK requirement, with no deployment-target restriction.
- When designing haptic effects, prefer using `sensoryFeedback()` over older UIKit APIs such as `UIImpactFeedbackGenerator`.
- Use the `@Entry` macro to define custom `EnvironmentValues`, `FocusedValues`, `Transaction`, and `ContainerValues` keys. This replaces the legacy pattern of manually creating a type conforming to (for example) `EnvironmentKey` with a `defaultValue`, then extending `EnvironmentValues` with a computed property. An `@Entry` default must remain equal across reads, and a custom action must not be a stored closure; see the `@Entry` hygiene rules in [state-management.md](state-management.md).
- When `overlay()`, `background()`, or `mask()` receives a view, use its builder closure rather than its soft-deprecated view-argument overload: `.mask { Image(systemName: "star.fill") }`. Some argument forms also fail in Xcode 27 because `blendMode` becomes ambiguous; for example, write `.overlay { Color.orange.blendMode(.multiply) }`. Style overloads remain correct, including `.background(.indigo)` and `.background(.indigo, in: .rect(cornerRadius: 12))`.
- Prefer toolbar placements that express purpose: `.cancellationAction` for canceling, `.confirmationAction` for confirming, and `.primaryAction` for the window's main action. Use `.automatic` when no semantic role fits. On iOS, never use the deprecated `.navigationBarLeading` or `.navigationBarTrailing`; the positional fallbacks there are `.topBarLeading` and `.topBarTrailing`.
- Prefer to rely on automatic grammar agreement when dealing with English, French, German, Portuguese, Spanish, and Italian. For example, use `Text("^[\(people) person](inflect: true)")` to show a number of people.
- You can fill and stroke a shape with two chained modifiers; you do *not* need an overlay for the stroke. The overlay was required previously, but this is fixed in iOS 17 and later.
- When referencing images from an asset catalog, prefer the generated symbol asset API when the project is configured to use them: `Image(.avatar)` rather than `Image("avatar")`.
- When targeting iOS 26 and later, SwiftUI has a native `WebView` view type that replaces almost all uses of hand-wrapped `WKWebView` inside `UIViewRepresentable`. To use it, make sure to include `import WebKit`.
- macOS 26+: `ForEach` over an `enumerated()` sequence should not convert to an array first; use `ForEach(items.enumerated(), id: \.element.id)` directly. The `RandomAccessCollection` conformance that allows this is gated to the 26 releases, so earlier targets keep `ForEach(Array(items.enumerated()), id: \.element.id)`.
- When hiding scroll indicators, use `.scrollIndicators(.hidden)` rather than `showsIndicators: false` in the initializer.
- Never concatenate `Text` values or construct a `Text` label by adding strings. For example, use `Text("Folder: \(folderName)")` instead of `Text("Folder: " + folderName)`: interpolation retains a localization key, while string addition produces a plain `String` whose literal prefix is not localized.

For example, the usage of `+` here is bad and deprecated:

```swift
Text("Hello").foregroundStyle(.red)
+
Text("World").foregroundStyle(.blue)
```

Instead, use text interpolation like this:

```swift
let red = Text("Hello").foregroundStyle(.red)
let blue = Text("World").foregroundStyle(.blue)
Text("\(red)\(blue)")
```


## Toolbars

- Place related controls, such as previous and next actions, in a `ToolbarItemGroup` instead of separate items divided by fixed spacers. The group adapts its spacing and, where supported, accepts one visibility priority for the whole set.
- macOS 26.1+ (above Ducko's 26.0 target, so behind `#available(macOS 26.1, *)`): assign `visibilityPriority(.high)` to frequent actions and items conveying status, and `.low` to expendable items. Without priorities, overflow starts at the trailing end without considering importance.
- macOS 27+: apply `contentMarginsRemoved()` to the `ToolbarItem` holding custom imagery when the glass should fit the image. Default margins otherwise produce an oversized pill around an image button or a glass border around a standalone image. Keep standard margins on ordinary buttons.
- With Xcode 27+, a `ForEach` may generate items directly within `toolbar()`, replacing the need to spell out each item on older toolchains. This needs no runtime availability branch.
- Toggle a toolbar item's `.hidden()` modifier instead of conditionally creating the item. For example, `ToolbarItem { Button("Export", systemImage: "square.and.arrow.up", action: export) }.hidden(!canExport)`.
- `ToolbarOverflowMenu` and `.topBarPinnedTrailing` are unavailable on macOS; the window toolbar manages its own overflow.

See also the macOS 26+ toolbar additions in [modern-apis.md](modern-apis.md) and window toolbar styling in [macos-window-styling.md](macos-window-styling.md).


## Using ObservableObject

If using `ObservableObject` is absolutely required – for example if you are trying to create a debouncer using a Combine publisher – you should always make sure `import Combine` is added. This was previously provided through SwiftUI, but that is no longer the case.


## Handling soft-deprecated APIs

This section covers *how to behave* when you encounter soft-deprecated SwiftUI APIs. For the deprecated-to-modern transitions themselves, see the list above and [modern-apis.md](modern-apis.md).

### What "soft-deprecated" means

A soft-deprecated API is marked deprecated in the SDK headers but with a placeholder deprecation version (`100000.0`) that suppresses compiler warnings. It still compiles and works correctly — it just signals that the API shouldn't be used in new code. Because Xcode stays quiet, review the source, and inspect a symbol's `@available` declaration in the SDK when its status is unclear. Examples include `NavigationView` (use `NavigationStack` / `NavigationSplitView`), `ActionSheet` / `Alert` (use the `.confirmationDialog` / `.alert` modifiers), `MagnificationGesture` (renamed `MagnifyGesture`), and `PresentationMode` (use `\.dismiss`).

Because these still work, treat them as **informational**, not urgent.

### Scoping rule — read this first

All soft-deprecation guidance is scoped to the code you are **directly modifying**. If a file contains several views and the task touches only one, the other views are out of scope.

- Only discuss the view(s) you actually edited.
- Do not mention, flag, or offer to migrate soft-deprecated APIs in code you weren't asked to change — including trailing "while I'm here, want me to migrate `OtherView`?" questions.
- This takes precedence over any prompt asking for "observations" or "other notes."

Mentioning soft-deprecated APIs in untouched code creates noise, distracts from the task, and pressures the user into unrelated work.

### When generating new code

Never introduce a new usage of a soft-deprecated API. If you're unsure whether an API is soft-deprecated, check [modern-apis.md](modern-apis.md) before recommending it — any API that worked in a prior release could have been soft-deprecated since.

### When asked to review, refactor, modernize, or clean up

Point out soft-deprecated APIs in the code under review and suggest the modern replacement. Keep the tone informational — these still compile and run, so frame migration as an improvement, not a bug fix.

### When asked to add a feature or fix a bug

If the view you're editing already uses a soft-deprecated API, **keep it as-is** in your change. Don't silently swap `NavigationView` for `NavigationStack` while adding a search bar — that produces unexpected diffs, risks regressions (state resets, navigation behavior changes), and makes the change harder to review. After delivering the requested change, you may add a brief one-line offer to migrate as a separate step.

If a *different* view in the same file uses a soft-deprecated API, ignore it entirely (see the scoping rule).

### General guidance

- Never introduce new usages of soft-deprecated APIs in code written from scratch.
- Don't proactively scan a codebase for soft-deprecated APIs — only notice them when they appear in code you're directly modifying for the user's request.
- Migrations are real edits with behavioral risk; they belong in their own focused change, not bundled into unrelated work.
