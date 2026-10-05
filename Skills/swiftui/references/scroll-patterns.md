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

For a chat transcript that must follow new rows, hold its place when older rows load, or keep a position per tab, use the AppKit-backed list described under [Chat Transcripts](#chat-transcripts) in place of this example. A `proxy.scrollTo` aimed at a row inserted in the same update does nothing; this example scrolls to a sentinel that already exists, which was not checked.

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

Ducko's transcripts are an AppKit table that hosts the SwiftUI rows in its cells (`Sources/DuckoUI/TranscriptList/`), not a SwiftUI scroll view. The list follows the newest row, keeps the reading position when older rows load or the window resizes, and keeps a position per tab. Use it for a new transcript-like surface, and read this section before changing it.

### Why not a SwiftUI stack

The figures below were measured on macOS 27.0.1 with real message rows.

- `LazyVStack` positions by estimated heights. Following the newest row goes through intermediate positions, a prepend settles tens of points off, and `ScrollViewProxy.scrollTo(id)` for a row inserted in the same update does nothing.
- An eager `VStack` with `ScrollPosition` and `.defaultScrollAnchor(.bottom)` holds exactly, but it lays out every mounted row. Mounting a real row takes about 1 ms, and each layout pass about 0.1 ms per mounted row. With 300 rows in each of five tabs, opening a chat took 385–812 ms, an incoming message 250–270 ms, and a resize step up to 271 ms. Keeping one list per tab mounted to preserve positions multiplies that cost by the number of tabs.
- The table measures only the rows near the screen: opening a chat takes 55–75 ms and a resize step 20–30 ms, whether 300 or 3,000 rows are loaded.

### How the list holds a position

- **Rows are values.** A hosted row draws only from its `TranscriptRow`, which is `Equatable`. A measured height is kept for as long as the row's value and the width are the same, so the height cache cannot disagree with what the row shows. Anything that can change a row's height belongs in the value, not in view state or in a service the row reads on its own.
- **Measure only what is near.** Heights are measured only for rows within one viewport of what is on screen. One reused `NSHostingController` measures them with `sizeThatFits(in:)` at the column width. Other rows keep their last known height or an estimate. Give the hosted content `.fixedSize(horizontal: false, vertical: true)`: measuring offers unlimited height, which flexible content such as a divider bar would otherwise fill.
- **Store a position, and put it back after every change.** The position is one of three: the newest message, a row and where its top sits in the viewport, or the top edge. The History window opens each day at the top edge. After a row change, a height change, or a resize, the list measures what is in reach and scrolls back to the stored position, repeating until nothing in reach is unmeasured. Left to itself the table moves what is on screen by the height of whatever was inserted above.
- **Do not put the view back after the reader's own scroll** unless that scroll brought unmeasured rows into reach. Re-positioning on every scroll movement cuts off the trackpad's elastic overscroll at either end and shows as a stutter.
- **Insert above only at rest.** Older rows are fetched while the reader scrolls and inserted once scrolling has come to rest. At rest means no live scroll is in progress and nothing has scrolled for 0.1 s. A live scroll runs from `NSScrollView.willStartLiveScrollNotification` to `didEndLiveScrollNotification`, which cover the gesture, its momentum, and the bounce. A mouse wheel posts no live-scroll notifications, so for it the quiet interval alone decides.
- **Derive "at the newest message" from where the view is,** never from where it was asked to go. State that depends on it, such as read receipts and a jump button, then changes on arrival.
- **One list, one position owner per tab.** The list is shared by all tabs. Each tab owns a scroller that keeps its position and its height cache, and the list shows whichever tab's rows it is handed.

### AppKit details that bite

- `noteHeightOfRows(withIndexesChanged:)` animates in a view-based table unless it runs inside an `NSAnimationContext` group of duration 0.
- After `reloadData()` or a row insert, the table takes its new size at its next layout and moves the clip view while doing so. Run `layoutSubtreeIfNeeded()` right after the change, under the same flag that marks the list's own moves, or that move is taken for the reader's scroll and overwrites the stored position.
- A table fills its scroll view, so its frame is no measure of how tall the rows are. Use the last row's `maxY`.
- A cell reused for another row carries the hosted row's `@State` along unless the hosted content's identity is reset per row (`.id(row.id)`).
- The list's first update arrives before it has a size. Whatever depends on geometry, such as asking for an older page, has to run again once the first layout has happened.
- An assignment to an observed property reaches `updateNSView` from a run-loop observer, never inside the assignment. Code that publishes rows cannot read what the list reports on the next line.
- A view laid over the list, such as the jump button, swallows the scroll wheel while the pointer is on it. Host it in an `NSHostingView` subclass that passes `scrollWheel(with:)` on to the scroll view. Give that host `sizingOptions = []` and fixed size constraints: a self-sizing hosting view takes part in the container's layout.
- Space below the newest row is a bottom content inset on the scroll view, not padding in a row. The document height the position rules use includes it.
- On a width change every height is a guess again. Measure only the rows on screen while the width keeps changing and the rest of the reach once it has held for a moment, or a resize step re-measures three viewports of rows.
- Under `swift test`, a table in a scroll view inside an `NSWindow(…, defer: true)` that is never shown has real geometry. Row rects, clip-view notifications, `insertRows`, a window resize, and realized hosted cells all work there. Live-scroll notifications cannot be produced there. The list is 17 pt narrower where the machine shows scroll bars always. That setting can change while the tests run, so a test must not depend on where rows wrap.

### Row content that keeps its height

A SwiftUI stack that is handed a height shares it out among its children by how much each can give, not by what each asks for. A `VStack` inside an `HStack` is always handed one, because an `HStack` passes its own height to its children. That holds in a `LazyVStack` as much as in a hosted cell. When a child that takes any height, such as a bare shape used as a bar, sits next to a long `Text`, the text is offered half and truncates, and the shape takes the rest. The row's total height is unchanged, so no measurement shows it. Give such a stack `.fixedSize(horizontal: false, vertical: true)`, as `MessageContentView` does.

## Summary Checklist

- [ ] Use `.scrollIndicators(.hidden)` instead of initializer parameter
- [ ] Use `ScrollViewReader` with stable IDs for programmatic scrolling
- [ ] Always use explicit animations with `scrollTo()`
- [ ] Use `.visualEffect` for scroll-based visual changes
- [ ] Use `.scrollTargetBehavior(.paging)` for paging behavior
- [ ] Use `.scrollTargetBehavior(.viewAligned)` for snap-to-item behavior
- [ ] Gate frequent scroll position updates by thresholds
- [ ] Use preference keys for custom scroll position tracking
- [ ] For a transcript that must hold its place, use the AppKit-backed list under Chat Transcripts instead of a SwiftUI scroll view
