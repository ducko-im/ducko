# SwiftUI Layout Best Practices Reference

## Relative Layout Over Constants

**Use dynamic layout calculations instead of hard-coded values.**

```swift
// Good - relative to actual layout
GeometryReader { geometry in
    VStack {
        HeaderView()
            .frame(height: geometry.size.height * 0.2)
        ContentView()
    }
}

// Avoid - magic numbers that don't adapt
VStack {
    HeaderView()
        .frame(height: 150)  // Doesn't adapt to different screens
    ContentView()
}
```

**Why**: Hard-coded values don't account for different screen sizes, orientations, or dynamic content (like status bars during phone calls).

## Context-Agnostic Views

**Views should work in any context.** Never assume presentation style or screen size.

```swift
// Good - adapts to given space
struct ProfileCard: View {
    let user: User
    
    var body: some View {
        VStack {
            Image(user.avatar)
                .resizable()
                .aspectRatio(contentMode: .fit)
            Text(user.name)
            Spacer()
        }
        .padding()
    }
}

// Avoid - assumes full screen
struct ProfileCard: View {
    let user: User
    
    var body: some View {
        VStack {
            Image(user.avatar)
                .frame(width: UIScreen.main.bounds.width)  // Wrong!
            Text(user.name)
        }
    }
}
```

**Why**: Views should work as full screens, modals, sheets, popovers, or embedded content.

## Own Your Container

**Custom views should own static containers but not lazy/repeatable ones.**

```swift
// Good - owns static container
struct HeaderView: View {
    var body: some View {
        HStack {
            Image(systemName: "star")
            Text("Title")
            Spacer()
        }
    }
}

// Avoid - missing container
struct HeaderView: View {
    var body: some View {
        Image(systemName: "star")
        Text("Title")
        // Caller must wrap in HStack
    }
}

// Good - caller owns lazy container
struct FeedView: View {
    let items: [Item]
    
    var body: some View {
        LazyVStack {
            ForEach(items) { item in
                ItemRow(item: item)
            }
        }
    }
}
```

## Layout Performance

### Avoid Layout Thrash

**Minimize deep view hierarchies and excessive layout dependencies.**

```swift
// Bad - deep nesting, excessive layout passes
VStack {
    HStack {
        VStack {
            HStack {
                VStack {
                    Text("Deep")
                }
            }
        }
    }
}

// Good - flatter hierarchy
VStack {
    Text("Shallow")
    Text("Structure")
}
```

**Avoid excessive `GeometryReader` and preference chains:**

```swift
// Bad - multiple geometry readers cause layout thrash
GeometryReader { outerGeometry in
    VStack {
        GeometryReader { innerGeometry in
            // Layout recalculates multiple times
        }
    }
}

// Good - single geometry reader or use alternatives (iOS 17+)
containerRelativeFrame(.horizontal) { width, _ in
    width * 0.8
}
```

**Gate frequent geometry updates:**

```swift
// Bad - updates on every pixel change
.onPreferenceChange(ViewSizeKey.self) { size in
    currentSize = size
}

// Good - gate by threshold
.onPreferenceChange(ViewSizeKey.self) { size in
    let difference = abs(size.width - currentSize.width)
    if difference > 10 {  // Only update if significant change
        currentSize = size
    }
}
```

## View Logic and Testability

### Separate View Logic from Views

**Place view logic into view models or similar, so it can be tested.**

> **iOS 17+**: Use `@Observable` macro with `@State` for view models.

```swift
// Good - logic in testable model (iOS 17+)
@Observable
@MainActor
final class LoginViewModel {
    var email = ""
    var password = ""
    var isValid: Bool {
        !email.isEmpty && password.count >= 8
    }

    func login() async throws {
        // Business logic here
    }
}

struct LoginView: View {
    @State private var viewModel = LoginViewModel()

    var body: some View {
        Form {
            TextField("Email", text: $viewModel.email)
            SecureField("Password", text: $viewModel.password)
            Button("Login") {
                Task {
                    try? await viewModel.login()
                }
            }
            .disabled(!viewModel.isValid)
        }
    }
}
```

> **iOS 16 and earlier**: Use `ObservableObject` protocol with `@StateObject`.

```swift
// Good - logic in testable model (iOS 16 and earlier)
@MainActor
final class LoginViewModel: ObservableObject {
    @Published var email = ""
    @Published var password = ""
    var isValid: Bool {
        !email.isEmpty && password.count >= 8
    }

    func login() async throws {
        // Business logic here
    }
}

struct LoginView: View {
    @StateObject private var viewModel = LoginViewModel()

    var body: some View {
        Form {
            TextField("Email", text: $viewModel.email)
            SecureField("Password", text: $viewModel.password)
            Button("Login") {
                Task {
                    try? await viewModel.login()
                }
            }
            .disabled(!viewModel.isValid)
        }
    }
}
```

```swift
// Bad - logic embedded in view
struct LoginView: View {
    @State private var email = ""
    @State private var password = ""
    
    var body: some View {
        Form {
            TextField("Email", text: $email)
            SecureField("Password", text: $password)
            Button("Login") {
                // Business logic directly in view - hard to test
                Task {
                    if !email.isEmpty && password.count >= 8 {
                        // Login logic...
                    }
                }
            }
        }
    }
}
```

**Note**: This is about separating business logic for testability, not about enforcing specific architectures like MVVM. The goal is to make logic testable while keeping views simple.

## Action Handlers

**Separate layout from logic.** View body should reference action methods, not contain logic.

```swift
// Good - action references method
struct PublishView: View {
    @State private var viewModel = PublishViewModel()
    
    var body: some View {
        Button("Publish Project", action: viewModel.handlePublish)
    }
}

// Avoid - logic in closure
struct PublishView: View {
    @State private var isLoading = false
    @State private var showError = false
    
    var body: some View {
        Button("Publish Project") {
            isLoading = true
            apiService.publish(project) { result in
                if case .error = result {
                    showError = true
                }
                isLoading = false
            }
        }
    }
}
```

**Why**: Separating logic from layout improves readability, testability, and maintainability.

## Summary Checklist

- [ ] Use relative layout over hard-coded constants
- [ ] Views work in any context (don't assume screen size)
- [ ] Custom views own static containers
- [ ] Avoid deep view hierarchies (layout thrash)
- [ ] Gate frequent geometry updates by thresholds
- [ ] View logic separated into testable models/classes
- [ ] Action handlers reference methods, not inline logic
- [ ] Avoid excessive `GeometryReader` usage
- [ ] Use `containerRelativeFrame()` when appropriate

## macOS Adaptive Bar / Window Sizing

Patterns for a horizontal bar (tab strip, toolbar) that must adapt to the window width, and for the window's own resize bounds.

**Budget inter-item spacing when dividing a measured width.** When you compute a per-item width by dividing an available width among N fixed-width items, subtract the `(N-1) * spacing` the `HStack` inserts between them. Omitting it makes the items sum to more than the content area, so the trailing item overflows the edge — and symmetric `.padding(.horizontal:)` won't fix it because the overflow scales with item count, not the inset.

```swift
// items fill `width` exactly: account for the gaps the HStack adds
let gaps = CGFloat(max(0, count - 1)) * spacing
let itemWidth = (width - gaps) / CGFloat(count)
```

Keep the flexible `Spacer`/trailing control in an OUTER `HStack(spacing: 0)` and the items in an INNER `HStack(spacing: spacing)`, so the spacer/control don't add stray gaps the math didn't budget.

**Wrap width-driven layout in `GeometryReader` to decouple it from the window's minimum size.** Fixed-width children inside a plain `HStack` make the stack's minimum width grow with child count — which forces a macOS window wider and blocks it from shrinking. A `GeometryReader` takes the offered width and proposes no minimum of its own, so the bar lays out within whatever the window gives without pinning or growing it. Constrain its greedy height with `.frame(height:)`. This is the exception to the "avoid `GeometryReader`" guidance above — a single, non-nested reader is the right tool here precisely because `containerRelativeFrame()` sizes to the container but doesn't shield the window's minimum-width computation from fixed-width children.

**Give a resizable singleton `Window` an explicit lower bound.** Once content no longer imposes a (growing) minimum, the window can be dragged to an unusable sliver. Add `.frame(minWidth:minHeight:)` to the content and `.windowResizability(.contentMinSize)` to the `Window` scene so it floors the window's minimum while still resizing freely above it. Pair with a one-line limit on header labels (`singleLine()` in DuckoUI) so they truncate instead of wrapping a character per line near the floor.

**Use `singleLine()` to show a tooltip only while one-line text is cut off** (`Sources/DuckoUI/Shared/Text+SingleLine.swift`). It chooses between two copies of the line with `ViewThatFits(in: .horizontal)`. `Text.Layout.isTruncated`, read through `Text.LayoutKey`, is no substitute: it reported `false` for text cut at a line break, and in a row benchmark it was slower than the fit check once the text was cut off. The fit check cost about 0.1 ms per text when rows were laid out in an off-screen hosting view, so the contact list's height-measuring pass sets `measuresHeightOnly` in the environment to skip it. Build text that may hold line breaks with `Text(joiningLines:)`, since a one-line label otherwise ends at the first break and counts as fitting.
