# SwiftUI State Management Reference

## Property Wrapper Selection Guide

| Wrapper | Use When | Notes |
|---------|----------|-------|
| `@State` | Internal view state that triggers updates | Must be `private` |
| `@Binding` | Child view needs to modify parent's state | Don't use for read-only |
| `@Bindable` | iOS 17+: View receives `@Observable` object and needs bindings | For injected observables |
| `let` | Read-only value passed from parent | Simplest option |
| `var` | Read-only value that child observes via `.onChange()` | For reactive reads |

**Legacy (Pre-iOS 17):**
| Wrapper | Use When | Notes |
|---------|----------|-------|
| `@StateObject` | View owns an `ObservableObject` instance | Use `@State` with `@Observable` instead |
| `@ObservedObject` | View receives an `ObservableObject` from outside | Never create inline |

## @State

Always mark `@State` properties as `private`. Use for internal view state that triggers UI updates.

```swift
// Correct
@State private var isAnimating = false
@State private var selectedTab = 0
```

**Why Private?** Marking state as `private` makes it clear what's created by the view versus what's passed in. It also prevents accidentally passing initial values that will be ignored (see "Don't Pass Values as @State" below).

### iOS 17+ with @Observable (Preferred)

**Always prefer `@Observable` over `ObservableObject`.** With iOS 17's `@Observable` macro, use `@State` instead of `@StateObject`:

```swift
@Observable
@MainActor  // Always mark @Observable classes with @MainActor
final class DataModel {
    var name = "Some Name"
    var count = 0
}

struct MyView: View {
    @State private var model = DataModel()  // Use @State, not @StateObject

    var body: some View {
        VStack {
            TextField("Name", text: $model.name)
            Stepper("Count: \(model.count)", value: $model.count)
        }
    }
}
```

**Note**: You may want to mark `@Observable` classes with `@MainActor` to ensure thread safety with SwiftUI, unless your project or package uses Default Actor Isolation set to `MainActor`—in which case, the explicit attribute is redundant and can be omitted.

## Make @Observable Property Types Equatable

The `@Observable` macro generates a setter that **skips invalidation when the new value equals the current one** — but only when the property's type is `Equatable`. Without that conformance, every assignment notifies observing views, even identical no-op writes. Make frequently-rewritten property types `Equatable` (a big win for polling or event-driven state that is often re-assigned the same value).

```swift
// AVOID: not Equatable — every assignment invalidates, even no-op writes
enum ConnectionPhase { case connecting, connected, degraded }

// PREFER: Equatable lets the generated setter short-circuit redundant writes
enum ConnectionPhase: Equatable { case connecting, connected, degraded }
```

Collections follow their element: an `Array`/`Set`/`Dictionary` is `Equatable` only when its element is, so a non-`Equatable` element defeats the short-circuit for the whole collection. This is distinct from `Equatable` *views* (which let SwiftUI skip a body) — this lets the model skip notifying observers in the first place.

## @Observable Dependency Granularity

Observation tracks reads at the **property** level, not the field level — reading any part of a compound property establishes a dependency on the whole thing. Three traps:

- **A computed property establishes dependencies transitively.** `var currentUser: User? { users.first { $0.id == currentID } }` reads `users`, so any view reading `currentUser` depends on the entire `users` array.
- **A struct-typed stored property drags the whole struct.** A view reading `session.user.name` depends on `session.user`; editing any other field of `user` invalidates it.
- **A collection read drags the whole collection.** Reading one element establishes a dependency on the entire stored collection.

These traps explain an update problem; they are not a reason to restructure a model up front. A cache has to be kept in sync on every update path, and an incomplete one shows stale UI, so apply the two remedies below only for an established problem such as excessive view updates.

For such a problem, cache derived values as stored properties kept in sync, rather than recomputing in a getter:

```swift
@MainActor @Observable
final class AppState {
    var users: [User] = [] { didSet { recomputeCurrentUser() } }
    var currentID: User.ID? { didSet { recomputeCurrentUser() } }

    private(set) var currentUser: User?
    private func recomputeCurrentUser() { currentUser = users.first { $0.id == currentID } }
}
```

For struct-typed properties behind such a problem, expose the individual fields views actually read as separate properties (each is then tracked separately). Reading several already-narrow properties from one model is fine and needs no splitting.

## @Binding

Use only when child view needs to **modify** parent's state. If child only reads the value, use `let` instead.

```swift
// Parent
struct ParentView: View {
    @State private var isSelected = false

    var body: some View {
        ChildView(isSelected: $isSelected)
    }
}

// Child - will modify the value
struct ChildView: View {
    @Binding var isSelected: Bool

    var body: some View {
        Button("Toggle") {
            isSelected.toggle()
        }
    }
}
```

### When NOT to use @Binding

```swift
// Bad - child only displays, doesn't modify
struct DisplayView: View {
    @Binding var title: String  // Unnecessary
    var body: some View {
        Text(title)
    }
}

// Good - use let for read-only
struct DisplayView: View {
    let title: String
    var body: some View {
        Text(title)
    }
}
```

## @StateObject vs @ObservedObject (Legacy - Pre-iOS 17)

**Note**: These are legacy patterns. Always prefer `@Observable` with `@State` for iOS 17+.

The key distinction is **ownership**:

- `@StateObject`: View **creates and owns** the object
- `@ObservedObject`: View **receives** the object from outside

```swift
// Legacy pattern - use @Observable instead
class MyViewModel: ObservableObject {
    @Published var items: [String] = []
}

// View creates it → @StateObject
struct OwnerView: View {
    @StateObject private var viewModel = MyViewModel()

    var body: some View {
        ChildView(viewModel: viewModel)
    }
}

// View receives it → @ObservedObject
struct ChildView: View {
    @ObservedObject var viewModel: MyViewModel

    var body: some View {
        List(viewModel.items, id: \.self) { Text($0) }
    }
}
```

### Common Mistake

Never create an `ObservableObject` inline with `@ObservedObject`:

```swift
// WRONG - creates new instance on every view update
struct BadView: View {
    @ObservedObject var viewModel = MyViewModel()  // BUG!
}

// CORRECT - owned objects use @StateObject
struct GoodView: View {
    @StateObject private var viewModel = MyViewModel()
}
```

### @StateObject instantiation in View's initializer (if it's a Parent view)

This approach is an anti-pattern in general. Prefer storing the StateObject in the parent view or wherever the model is actually owned, then pass it down (use @ObservedObject, @EnvironmentObject, or @Bindable (for @Observable)) to keep ownership and lifecycle explicit.
If you need to create a @StateObject with initialization parameters in your view's custom initializer, be aware of redundant allocations and hidden side effects.

```swift
// WRONG - creates a new ViewModel instance each time the view's initializer is called
// (which can happen multiple times during SwiftUI's structural identity evaluation)
struct MovieDetailsView: View {
    
    @StateObject private var viewModel: MovieDetailsViewModel
    
    init(movie: Movie) {
        let viewModel = MovieDetailsViewModel(movie: movie)
        _viewModel = StateObject(wrappedValue: viewModel)      
    }
    
    var body: some View {
        // ...
    }
}

// CORRECT - creation in @autoclosure prevents multiple instantiations
struct MovieDetailsView: View {
    
    @StateObject private var viewModel: MovieDetailsViewModel
    
    init(movie: Movie) {
        _viewModel = StateObject(
            wrappedValue: MovieDetailsViewModel(movie: movie)
        )      
    }
    
    var body: some View {
        // ...
    }
}
```

**Modern Alternative**: Use `@Observable` with `@State` instead of `ObservableObject` patterns.

## Don't Pass Values as @State

**Critical**: Never declare passed values as `@State` or `@StateObject`. The value you provide is only an initial value and won't update.

```swift
// Parent
struct ParentView: View {
    @State private var item = Item(name: "Original")
    
    var body: some View {
        ChildView(item: item)
        Button("Change") {
            item.name = "Updated"  // Child won't see this!
        }
    }
}

// Wrong - child ignores updates from parent
struct ChildView: View {
    @State var item: Item  // Accepts initial value only!
    
    var body: some View {
        Text(item.name)  // Shows "Original" forever
    }
}

// Correct - child receives updates
struct ChildView: View {
    let item: Item  // Or @Binding if child needs to modify
    
    var body: some View {
        Text(item.name)  // Updates when parent changes
    }
}
```

**Why**: `@State` and `@StateObject` retain values between view updates. That's their purpose. When a parent passes a new value, the child reuses its existing state.

**Prevention**: Always mark `@State` and `@StateObject` as `private`. This prevents them from appearing in the generated initializer.

## @Bindable (iOS 17+)

Use when receiving an `@Observable` object from outside and needing bindings:

```swift
@Observable
final class UserModel {
    var name = ""
    var email = ""
}

struct ParentView: View {
    @State private var user = UserModel()

    var body: some View {
        EditUserView(user: user)
    }
}

struct EditUserView: View {
    @Bindable var user: UserModel  // Received from parent, needs bindings

    var body: some View {
        Form {
            TextField("Name", text: $user.name)
            TextField("Email", text: $user.email)
        }
    }
}
```

## let vs var for Passed Values

### Use `let` for read-only display

```swift
struct ProfileHeader: View {
    let username: String
    let avatarURL: URL

    var body: some View {
        HStack {
            AsyncImage(url: avatarURL)
            Text(username)
        }
    }
}
```

### Use `var` when reacting to changes with `.onChange()`

```swift
struct ReactiveView: View {
    var externalValue: Int  // Watch with .onChange()
    @State private var displayText = ""

    var body: some View {
        Text(displayText)
            .onChange(of: externalValue) { oldValue, newValue in
                displayText = "Changed from \(oldValue) to \(newValue)"
            }
    }
}
```

## Environment and Preferences

### @Environment

Access environment values provided by SwiftUI or parent views:

```swift
struct MyView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Button("Done") { dismiss() }
            .foregroundStyle(colorScheme == .dark ? .white : .black)
    }
}
```

### Custom Environment Values with @Entry (hygiene)

Use the `@Entry` macro (Xcode 16+) to define custom environment values without `EnvironmentKey` boilerplate. Three rules keep them from causing spurious invalidations:

- **Never store a closure in a custom environment key.** SwiftUI can't compare function values, so any view reading a closure-valued key invalidates on *every* environment write. Wrapping the closure in a struct doesn't help. Defunctionalize: store the captured data as properties and expose behavior via `callAsFunction` or a method (or use an `@Observable` model). Framework action types (`\.openURL`, `\.dismiss`, `\.refresh`) are the intended exception.

  ```swift
  // AVOID: closure in a custom environment key
  extension EnvironmentValues { @Entry var submit: (String) -> Void = { _ in } }

  // PREFER: a defunctionalized struct
  struct SubmitAction { func callAsFunction(_ draft: String) { /* ... */ } }
  extension EnvironmentValues { @Entry var submit = SubmitAction() }
  ```

- **Keep `@Entry` defaults stable.** `@Entry` re-evaluates its default expression on every read that falls back to it. A fresh reference (`Model()`) or a runtime value (`Date()`, `UUID()`) makes readers using the default invalidate on every unrelated environment write. Back the default with a literal, enum case, `nil`, or a `static let`-backed instance.

- **Remove unused `@Environment` reads.** Declaring `@Environment(\.someKey)` subscribes the view to that key even if `body` never uses it, so every write re-evaluates the view for nothing. Delete unreferenced declarations. (The type form `@Environment(Model.self)` tracks at the property level and carries no such cost.)

### @Environment with @Observable (iOS 17+ - Preferred)

**Always prefer this pattern** for sharing state through the environment:

```swift
@Observable
@MainActor
final class AppState {
    var isLoggedIn = false
}

// Inject
ContentView()
    .environment(AppState())

// Access
struct ChildView: View {
    @Environment(AppState.self) private var appState
}
```

### @EnvironmentObject (Legacy - Pre-iOS 17)

Legacy pattern for sharing observable objects through the environment:

```swift
// Legacy pattern - use @Observable with @Environment instead
class AppState: ObservableObject {
    @Published var isLoggedIn = false
}

// Inject at root
ContentView()
    .environmentObject(AppState())

// Access in child
struct ChildView: View {
    @EnvironmentObject var appState: AppState
}
```

## Decision Flowchart

```
Is this value owned by this view?
├─ YES: Is it a simple value type?
│       ├─ YES → @State private var
│       └─ NO (class):
│           ├─ Use @Observable → @State private var (mark class @MainActor)
│           └─ Legacy ObservableObject → @StateObject private var
│
└─ NO (passed from parent):
    ├─ Does child need to MODIFY it?
    │   ├─ YES → @Binding var
    │   └─ NO: Does child need BINDINGS to its properties?
    │       ├─ YES (@Observable) → @Bindable var
    │       └─ NO: Does child react to changes?
    │           ├─ YES → var + .onChange()
    │           └─ NO → let
    │
    └─ Is it a legacy ObservableObject from parent?
        └─ YES → @ObservedObject var (consider migrating to @Observable)
```

## State Privacy Rules

**All view-owned state should be `private`:**

```swift
// Correct - clear what's created vs passed
struct MyView: View {
    // Created by view - private
    @State private var isExpanded = false
    @State private var viewModel = ViewModel()
    @AppStorage("theme") private var theme = "light"
    @Environment(\.colorScheme) private var colorScheme
    
    // Passed from parent - not private
    let title: String
    @Binding var isSelected: Bool
    @Bindable var user: User
    
    var body: some View {
        // ...
    }
}
```

**Why**: This makes dependencies explicit and improves code completion for the generated initializer.

## Avoid Nested ObservableObject

**Note**: This limitation only applies to `ObservableObject`. `@Observable` fully supports nested observed objects.

```swift
// Avoid - breaks animations and change tracking
class Parent: ObservableObject {
    @Published var child: Child  // Nested ObservableObject
}

class Child: ObservableObject {
    @Published var value: Int
}

// Workaround - pass child directly to views
struct ParentView: View {
    @StateObject private var parent = Parent()
    
    var body: some View {
        ChildView(child: parent.child)  // Pass nested object directly
    }
}

struct ChildView: View {
    @ObservedObject var child: Child
    
    var body: some View {
        Text("\(child.value)")
    }
}
```

**Why**: SwiftUI can't track changes through nested `ObservableObject` properties. Manual workarounds break animations. With `@Observable`, this isn't an issue.

## Key Principles

1. **Always prefer `@Observable` over `ObservableObject`** for new code
2. **Mark `@Observable` classes with `@MainActor` for thread safety (unless using default actor isolation)`**
3. Use `@State` with `@Observable` classes (not `@StateObject`)
4. Use `@Bindable` for injected `@Observable` objects that need bindings
5. **Always mark `@State` and `@StateObject` as `private`**
6. **Never declare passed values as `@State` or `@StateObject`**
7. With `@Observable`, nested objects work fine; with `ObservableObject`, pass nested objects directly to child views
8. **Prefer `Equatable` types for frequently-written `@Observable` properties** so the generated setter skips redundant invalidations
9. **For an established update problem, cache derived values as stored properties** instead of computed getters that read whole collections or structs
10. **Never store closures in custom environment keys; keep `@Entry` defaults stable** (no `Model()`/`Date()` expressions); remove unused `@Environment` reads
