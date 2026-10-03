# SwiftUI ScrollView Patterns Reference

## ScrollView Modifiers

### Hiding Scroll Indicators

**Use `.scrollIndicators(.hidden)` modifier instead of initializer parameter.**

```swift
// Modern (Correct)
ScrollView {
    content
}
.scrollIndicators(.hidden)

// Legacy (Avoid)
ScrollView(showsIndicators: false) {
    content
}
```

## ScrollViewReader for Programmatic Scrolling

**Use `ScrollViewReader` for scroll-to-top, scroll-to-bottom, and anchor-based jumps.**

```swift
struct ChatView: View {
    @State private var messages: [Message] = []
    private let bottomID = "bottom"
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack {
                    ForEach(messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation {
                    proxy.scrollTo(bottomID, anchor: .bottom)
                }
            }
            .onAppear {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }
}
```

For a chat transcript that must follow new rows, hold its place when older rows load, or keep a position per tab, use the patterns under [Chat Transcripts](#chat-transcripts) in place of this example. A `proxy.scrollTo` aimed at a row inserted in the same update does nothing; this example scrolls to a sentinel that already exists, which was not checked.

### Scroll-to-Top Pattern

```swift
struct FeedView: View {
    @State private var items: [Item] = []
    @State private var scrollToTop = false
    private let topID = "top"
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack {
                    Color.clear
                        .frame(height: 1)
                        .id(topID)
                    
                    ForEach(items) { item in
                        ItemRow(item: item)
                    }
                }
            }
            .onChange(of: scrollToTop) { _, shouldScroll in
                if shouldScroll {
                    withAnimation {
                        proxy.scrollTo(topID, anchor: .top)
                    }
                    scrollToTop = false
                }
            }
        }
    }
}
```

**Why**: `ScrollViewReader` provides programmatic scroll control with stable anchors. Always use stable IDs and explicit animations.

## Scroll Position Tracking

### Basic Scroll Position

**Avoid** - Storing scroll position directly triggers view updates on every scroll frame:

```swift
// ❌ Bad Practice - causes unnecessary re-renders
struct ContentView: View {
    @State private var scrollPosition: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geometry.frame(in: .named("scroll")).minY
                            )
                    }
                )
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            scrollPosition = value
        }
    }
}
```

**Preferred** - Check scroll position and update a flag based on thresholds for smoother, more efficient scrolling:

```swift
// ✅ Good Practice - only updates state when crossing threshold
struct ContentView: View {
    @State private var startAnimation: Bool = false

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { geometry in
                        Color.clear
                            .preference(
                                key: ScrollOffsetPreferenceKey.self,
                                value: geometry.frame(in: .named("scroll")).minY
                            )
                    }
                )
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
            if value < -100 {
                startAnimation = true
            } else {
                startAnimation = false
            }
        }
    }
}

struct ScrollOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}
```

### Scroll-Based Header Visibility

```swift
struct ContentView: View {
    @State private var showHeader = true
    
    var body: some View {
        VStack(spacing: 0) {
            if showHeader {
                HeaderView()
                    .transition(.move(edge: .top))
            }
            
            ScrollView {
                content
                    .background(
                        GeometryReader { geometry in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: geometry.frame(in: .named("scroll")).minY
                                )
                        }
                    )
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                if offset < -50 { // Scrolling down
                   withAnimation { showHeader = false }
                } else if offset > 50 { // Scrolling up
                  withAnimation { showHeader = true }
                }
            }
        }
    }
}
```

## Scroll Transitions and Effects

> **iOS 17+**: All APIs in this section require iOS 17 or later.

### Scroll-Based Opacity

```swift
struct ParallaxView: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                ForEach(items) { item in
                    ItemCard(item: item)
                        .visualEffect { content, geometry in
                            let frame = geometry.frame(in: .scrollView)
                            let distance = min(0, frame.minY)
                            return content
                                .opacity(1 + distance / 200)
                        }
                }
            }
        }
    }
}
```

### Parallax Effect

```swift
struct ParallaxHeader: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Image("hero")
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 300)
                    .visualEffect { content, geometry in
                        let offset = geometry.frame(in: .scrollView).minY
                        return content
                            .offset(y: offset > 0 ? -offset * 0.5 : 0)
                    }
                    .clipped()
                
                ContentView()
            }
        }
    }
}
```

## Scroll Target Behavior

> **iOS 17+**: All APIs in this section require iOS 17 or later.

### Paging ScrollView

```swift
struct PagingView: View {
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(pages) { page in
                    PageView(page: page)
                        .containerRelativeFrame(.horizontal)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
    }
}
```

### Snap to Items

```swift
struct SnapScrollView: View {
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 16) {
                ForEach(items) { item in
                    ItemCard(item: item)
                        .frame(width: 280)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.viewAligned)
        .contentMargins(.horizontal, 20)
    }
}
```

## Chat Transcripts

> **iOS 18+ / macOS 15+**: `ScrollPosition`, `onScrollGeometryChange`, and `onScrollPhaseChange`. The behaviors below were observed on macOS 27.0.1, not taken from documentation; re-check them on the deployment target's oldest OS.

For a chat transcript this section takes precedence over the general rules in this skill: use an eager stack where they say lazy, `ScrollPosition` where they say `ScrollViewReader`, and unanimated scrolls for following and holding. It assumes a bounded transcript, one that loads a limited window of rows and pages the rest, sized so the whole stack lays out without a visible delay; measure that with real rows.

### Follow the newest row

- Scroll with `ScrollPosition`: `@State private var position = ScrollPosition(idType: Row.ID.self, edge: .bottom)`, bound via `.scrollPosition($position, anchor: .bottom)`, with `.scrollTargetLayout()` on the stack. `position.scrollTo(edge: .bottom)` works in the same update that appends a row. `ScrollViewProxy.scrollTo(id)` for a row inserted in that same update has no effect, in lazy and eager stacks alike.
- Lay out a bounded transcript eagerly (`VStack`). With `.defaultScrollAnchor(.bottom)` a view resting at the bottom edge stays there through appends, row growth, prepends, and viewport resizes, exactly and in one geometry update, with no explicit scroll. `LazyVStack` positions by estimated heights: it reaches the bottom through intermediate positions and can settle tens of points off after a prepend.
- Derive "is at the bottom" from `onScrollGeometryChange` only (`contentSize.height - contentOffset.y - containerSize.height`). Requesting a scroll to the bottom leaves that flag as it is; it turns true when geometry reports the arrival, so state that depends on it (read receipts, a jump button) changes on arrival. Assign it only when its value changes, and keep per-frame values such as offsets and frames out of observed state.

### Hold the reading position across a prepend

No anchor configuration keeps a scrolled-up reader in place when rows are inserted above: the offset stays and the content moves down. Hold it in the same update as the insert:

```swift
// The reference is a 1 pt marker view at the end of the stack with .id(endID).
// endFrame: its frame in .scrollView space, reported by onGeometryChange.
// viewportHeight: containerSize.height from onScrollGeometryChange.
// Both are stored outside observed state; position is the bound ScrollPosition.
let anchor = UnitPoint(x: 0.5, y: endFrame.minY / (viewportHeight - endFrame.height))
rows.insert(contentsOf: olderRows, at: 0)
position.scrollTo(id: endID, anchor: anchor)
```

- Exact in an eager stack, including anchor values far outside `0...1` (a reference far below the viewport). Inexact in a lazy stack.
- Keep the reference small: the formula divides by the viewport height minus the reference's height.
- Insert only while the scroll phase is idle (`onScrollPhaseChange`); park the fetched rows until then.
- Use the hold only for changes above the reader. A change that also adds rows between the reader and the end marker pushes the marker down by their height, and holding the marker then moves the reader up by that much.
- After the insert the corrected offset is reported a few milliseconds later, sometimes in a later run-loop pass. Wait for it before re-reading scroll geometry, for example before deciding whether to load another page.

### Keep a position per tab

Keep one list per open tab mounted in a `ZStack` and show only the selected one (`opacity`, `allowsHitTesting`, `accessibilityHidden` on the rest). Each hidden list keeps its own position through tab switches, appends, and window resizes. Rebuilding a list and restoring its position is fragile: a scroll issued in `onAppear` is overridden unless that mount uses `.defaultScrollAnchor(.top, for: .initialOffset)`, and an anchor saved against one viewport height restores to a different place in another.

## Summary Checklist

- [ ] Use `.scrollIndicators(.hidden)` instead of initializer parameter
- [ ] Use `ScrollViewReader` with stable IDs for programmatic scrolling
- [ ] Always use explicit animations with `scrollTo()`
- [ ] Use `.visualEffect` for scroll-based visual changes
- [ ] Use `.scrollTargetBehavior(.paging)` for paging behavior
- [ ] Use `.scrollTargetBehavior(.viewAligned)` for snap-to-item behavior
- [ ] Gate frequent scroll position updates by thresholds
- [ ] Use preference keys for custom scroll position tracking
- [ ] For chat transcripts, follow Chat Transcripts where it differs from the items above: `ScrollPosition` on an eager stack, unanimated follow and hold, per-frame geometry kept out of observed state
