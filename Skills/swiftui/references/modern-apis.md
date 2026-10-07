# Modern SwiftUI APIs Reference

## Overview

This reference covers modern SwiftUI API usage patterns and deprecated API replacements. Always use the latest APIs to ensure forward compatibility and access to new features.

## Styling and Appearance

### foregroundStyle() vs foregroundColor()

**Always use `foregroundStyle()` instead of `foregroundColor()`.**

```swift
// Modern (Correct)
Text("Hello")
    .foregroundStyle(.primary)

Image(systemName: "star")
    .foregroundStyle(.blue)

// Legacy (Avoid)
Text("Hello")
    .foregroundColor(.primary)
```

**Why**: `foregroundStyle()` supports hierarchical styles, gradients, and materials, making it more flexible and future-proof.

### clipShape() vs cornerRadius()

**Always use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`.**

```swift
// Modern (Correct)
Image("photo")
    .clipShape(.rect(cornerRadius: 12))

VStack {
    // content
}
.clipShape(.rect(cornerRadius: 16))

// Legacy (Avoid)
Image("photo")
    .cornerRadius(12)
```

**Why**: `cornerRadius()` is deprecated. `clipShape()` is more explicit and supports all shape types.

### fontWeight() vs bold()

**Don't apply `fontWeight()` unless there's a good reason. Always use `bold()` for bold text.**

```swift
// Correct
Text("Important")
    .bold()

// Avoid (unless you need a specific weight)
Text("Important")
    .fontWeight(.bold)

// Acceptable (specific weight needed)
Text("Semibold")
    .fontWeight(.semibold)
```

## Navigation

### NavigationStack vs NavigationView

**Always use `NavigationStack` instead of `NavigationView`.**

```swift
// Modern (Correct)
NavigationStack {
    List(items) { item in
        NavigationLink(value: item) {
            Text(item.name)
        }
    }
    .navigationDestination(for: Item.self) { item in
        DetailView(item: item)
    }
}

// Legacy (Avoid)
NavigationView {
    List(items) { item in
        NavigationLink(destination: DetailView(item: item)) {
            Text(item.name)
        }
    }
}
```

### navigationDestination(for:)

**Use `navigationDestination(for:)` for type-safe navigation.**

```swift
struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                NavigationLink("Profile", value: Route.profile)
                NavigationLink("Settings", value: Route.settings)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .profile:
                    ProfileView()
                case .settings:
                    SettingsView()
                }
            }
        }
    }
}

enum Route: Hashable {
    case profile
    case settings
}
```

## Tabs

### Tab API vs tabItem()

**For iOS 18 and later, prefer the `Tab` API over `tabItem()` to access modern tab features, and use availability checks or `tabItem()` for earlier OS versions.**

```swift
// Modern (Correct) - iOS 18+
TabView {
    Tab("Home", systemImage: "house") {
        HomeView()
    }
    
    Tab("Search", systemImage: "magnifyingglass") {
        SearchView()
    }
    
    Tab("Profile", systemImage: "person") {
        ProfileView()
    }
}

// Legacy (Avoid)
TabView {
    HomeView()
        .tabItem {
            Label("Home", systemImage: "house")
        }
}
```

**Important**: When using `Tab(role:)` with roles, you must use the new `Tab { } label: { }` syntax for all tabs. Mixing with `.tabItem()` causes compilation errors.

```swift
// Correct - all tabs use Tab syntax
TabView {
    Tab(role: .search) {
        SearchView()
    } label: {
        Label("Search", systemImage: "magnifyingglass")
    }
    
    Tab {
        HomeView()
    } label: {
        Label("Home", systemImage: "house")
    }
}

// Wrong - mixing Tab and tabItem causes errors
TabView {
    Tab(role: .search) {
        SearchView()
    } label: {
        Label("Search", systemImage: "magnifyingglass")
    }
    
    HomeView()  // Error: can't mix with Tab(role:)
        .tabItem {
            Label("Home", systemImage: "house")
        }
}
```

## Interactions

### Button vs onTapGesture()

**Never use `onTapGesture()` unless you specifically need tap location or tap count. Always use `Button` otherwise.**

```swift
// Correct - standard tap action
Button("Tap me") {
    performAction()
}

// Correct - need tap location
Text("Tap anywhere")
    .onTapGesture { location in
        handleTap(at: location)
    }

// Correct - need tap count
Image("photo")
    .onTapGesture(count: 2) {
        handleDoubleTap()
    }

// Wrong - use Button instead
Text("Tap me")
    .onTapGesture {
        performAction()
    }
```

**Why**: `Button` provides proper accessibility, visual feedback, and semantic meaning. Use `onTapGesture()` only when you need its specific features.

### Button with Images

**Always specify text alongside images in buttons for accessibility.**

```swift
// Correct - includes text label
Button("Add Item", systemImage: "plus") {
    addItem()
}

// Also correct - custom label
Button {
    addItem()
} label: {
    Label("Add Item", systemImage: "plus")
}

// Wrong - image only, no text
Button {
    addItem()
} label: {
    Image(systemName: "plus")
}
```

## Layout and Sizing

### Avoid UIScreen.main.bounds

**Never use `UIScreen.main.bounds` to read available space.**

```swift
// Wrong - uses UIKit, doesn't respect safe areas
let screenWidth = UIScreen.main.bounds.width

// Correct - use GeometryReader
GeometryReader { geometry in
    Text("Width: \(geometry.size.width)")
}

// Better - use containerRelativeFrame (iOS 17+)
Text("Full width")
    .containerRelativeFrame(.horizontal)

// Best - let SwiftUI handle sizing
Text("Auto-sized")
    .frame(maxWidth: .infinity)
```

### GeometryReader Alternatives

> **iOS 17+**: `containerRelativeFrame` and `visualEffect` require iOS 17 or later.

**Don't use `GeometryReader` if a newer alternative works.**

```swift
// Modern - containerRelativeFrame
Image("hero")
    .resizable()
    .containerRelativeFrame(.horizontal) { length, axis in
        length * 0.8
    }

// Modern - visualEffect for position-based effects
Text("Parallax")
    .visualEffect { content, geometry in
        content.offset(y: geometry.frame(in: .global).minY * 0.5)
    }

// Legacy - only use if necessary
GeometryReader { geometry in
    Image("hero")
        .frame(width: geometry.size.width * 0.8)
}
```

## Type Erasure

### Avoid AnyView

**Avoid `AnyView` unless absolutely required.**

```swift
// Prefer - use @ContentBuilder (the Xcode 27+ name for @ViewBuilder)
@ContentBuilder
func content() -> some View {
    if condition {
        Text("Option A")
    } else {
        Image(systemName: "photo")
    }
}

// Avoid - type erasure has performance cost
func content() -> AnyView {
    if condition {
        return AnyView(Text("Option A"))
    } else {
        return AnyView(Image(systemName: "photo"))
    }
}

// Acceptable - when protocol conformance requires it
var body: some View {
    // Complex conditional logic that requires type erasure
}
```

## Styling Best Practices

### Dynamic Type

**Don't force specific font sizes. Prefer Dynamic Type.**

```swift
// Correct - respects user's text size preferences
Text("Title")
    .font(.title)

Text("Body")
    .font(.body)

// Avoid - fixed size doesn't scale
Text("Title")
    .font(.system(size: 24))
```

### UIKit Colors

**Avoid using UIKit colors in SwiftUI code.**

```swift
// Correct - SwiftUI colors
Text("Hello")
    .foregroundStyle(.blue)
    .background(.gray.opacity(0.2))

// Wrong - UIKit colors
Text("Hello")
    .foregroundColor(Color(UIColor.systemBlue))
    .background(Color(UIColor.systemGray))
```

## Static Member Lookup

**Prefer static member lookup to struct instances.**

```swift
// Correct - static member lookup
Circle()
    .fill(.blue)
Button("Action") { }
    .buttonStyle(.borderedProminent)

// Verbose - unnecessary struct instantiation
Circle()
    .fill(Color.blue)
Button("Action") { }
    .buttonStyle(BorderedProminentButtonStyle())
```

## Additional modern replacements

These are the net-new modern-API transitions most relevant to a macOS 26 SwiftUI app. For *how to behave* around a soft-deprecated API you encounter (when to migrate vs leave alone), see the soft-deprecation section in [api.md](api.md).

### Section trailing-closure initializers

Prefer content/header/footer trailing-closure `Section` initializers over the positional `header:`/`footer:` `View` arguments (those are being deprecated). The single-title `Section("Title")` form is still current.

```swift
// Current — single-title
Section("Settings") { Toggle("Notifications", isOn: $enabled) }

// Preferred when you need a footer or a View header
Section {
    Toggle("Notifications", isOn: $enabled)
} footer: {
    Text("Changes apply immediately.")
}

// Deprecated — positional header/footer View arguments
Section(header: Text("Settings"), footer: Text("…")) { … }
```

### Presentation: confirmationDialog / alert

Use the modifier forms `confirmationDialog(_:isPresented:actions:message:)` and `alert(_:isPresented:actions:message:)` instead of the old `ActionSheet` / `Alert`-value APIs.

```swift
.alert("Delete conversation?", isPresented: $showAlert) {
    Button("Delete", role: .destructive) { delete() }
    Button("Cancel", role: .cancel) { }
} message: {
    Text("This cannot be undone.")
}
```

### Text input: onSubmit + focused

Use `onSubmit` and `focused(_:equals:)` instead of `TextField`'s `onCommit` / `onEditingChanged` callbacks. See [focus-patterns.md](focus-patterns.md) for the full focus system.

```swift
TextField("Search", text: $query)
    .focused($isFocused)
    .onSubmit { performSearch() }
```

### Events: modern onChange arity

`onChange(of:perform:)` (single-parameter closure) is deprecated. Use the two-parameter or no-parameter form.

```swift
.onChange(of: value) { }              // no-parameter (most common)
.onChange(of: value) { old, new in }  // old + new
.onChange(of: value, initial: true) { } // also fire on appear
```

### Custom environment values: @Entry

Use the `@Entry` macro instead of hand-written `EnvironmentKey` conformance (also works for `FocusedValues` and container values). Back-deploys via Xcode 16+.

```swift
extension EnvironmentValues {
    @Entry var myValue: String = "Default"
}
```

### Gesture renames

- `MagnifyGesture` instead of `MagnificationGesture` (magnitude via `value.magnification`)
- `RotateGesture` instead of `RotationGesture` (angle via `value.rotation`)

### macOS 26+ toolbars and animation

- `ToolbarSpacer(.fixed)` / `ToolbarSpacer(.flexible)` to group or push apart toolbar items.
- `sharedBackgroundVisibility(.hidden)` to drop the glass group background from an individual toolbar item.
- `badge(_:)` on toolbar item content to show an indicator.
- `@Animatable` macro instead of hand-written `animatableData`; exclude properties with `@AnimatableIgnored`.

```swift
@Animatable
struct Wedge: Shape {
    var startAngle: Angle
    var endAngle: Angle
    @AnimatableIgnored var clockwise: Bool
    func path(in rect: CGRect) -> Path { /* … */ }
}
```

## Summary Checklist

- [ ] Use `foregroundStyle()` instead of `foregroundColor()`
- [ ] Use `clipShape(.rect(cornerRadius:))` instead of `cornerRadius()`
- [ ] Use `Tab` API instead of `tabItem()`
- [ ] Use `Button` instead of `onTapGesture()` (unless need location/count)
- [ ] Use `NavigationStack` instead of `NavigationView`
- [ ] Use `navigationDestination(for:)` for type-safe navigation
- [ ] Avoid `AnyView` unless required
- [ ] Avoid `UIScreen.main.bounds`
- [ ] Avoid `GeometryReader` when alternatives exist
- [ ] Use Dynamic Type instead of fixed font sizes
- [ ] Avoid hard-coded padding/spacing unless requested
- [ ] Avoid UIKit colors in SwiftUI
- [ ] Use static member lookup (`.blue` vs `Color.blue`)
- [ ] Include text labels with button images
- [ ] Use `bold()` instead of `fontWeight(.bold)`
- [ ] Use trailing-closure `Section` initializers instead of positional `header:`/`footer:` View args
- [ ] Use `confirmationDialog`/`alert` modifiers instead of `ActionSheet`/`Alert` values
- [ ] Use `onSubmit` + `focused` instead of `TextField` `onCommit`/`onEditingChanged`
- [ ] Use two- or no-parameter `onChange(of:)` instead of the single-parameter closure
- [ ] Use the `@Entry` macro instead of manual `EnvironmentKey` conformance
- [ ] Use `MagnifyGesture`/`RotateGesture` instead of `MagnificationGesture`/`RotationGesture`
- [ ] Use `@Animatable` macro instead of hand-written `animatableData`
