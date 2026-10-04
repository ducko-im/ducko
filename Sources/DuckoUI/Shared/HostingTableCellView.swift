import AppKit
import SwiftUI

/// `NSTableCellView` hosting one SwiftUI row, pinned to the cell.
final class HostingTableCellView<Content: View>: NSTableCellView {
    private let host: NSHostingView<Content>

    var content: Content {
        host.rootView
    }

    /// Without `sizingOptions` the hosting view keeps its own, under which the row's fitting size takes part in the
    /// cell's layout. An empty set keeps the hosting view out of the cell's sizing.
    init(content: Content, sizingOptions: NSHostingSizingOptions? = nil) {
        self.host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        if let sizingOptions {
            host.sizingOptions = sizingOptions
        }
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(content: Content) {
        host.rootView = content
    }
}

extension CollectionDifference {
    /// The offsets a table removes rows at, in the old order, and inserts rows at, in the new one.
    var rowChanges: (removals: IndexSet, insertions: IndexSet) {
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in self {
            switch change {
            case let .remove(offset, _, _): removals.insert(offset)
            case let .insert(offset, _, _): insertions.insert(offset)
            }
        }
        return (removals, insertions)
    }
}
