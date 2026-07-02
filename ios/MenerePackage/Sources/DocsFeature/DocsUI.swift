import FamilyDomain
import MenereUI
import SwiftUI

/// A countdown chip for a document's `dueDate` / `expiryDate`. Terracotta when the date is within
/// 30 days (or past-due); ink-soft when it's further out. Reused on the library row, the detail
/// screen, and the Today "Needs attention" card so the whole app speaks about time the same way.
public struct DocumentDateChip: View {
    public enum Kind { case due, expiry }

    let date: Date
    let kind: Kind

    public init(date: Date, kind: Kind) {
        self.date = date
        self.kind = kind
    }

    public var body: some View {
        Label(text, systemImage: kind == .expiry ? "hourglass" : "calendar.badge.clock")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .accessibilityIdentifier(kind == .expiry ? "doc-expiry-chip" : "doc-due-chip")
    }

    private var days: Int { FamilyDomain.Document.dayCount(from: Date(), to: date) }

    private var color: Color { days <= 30 ? .terracotta : .inkSoft }

    private var text: String {
        let n = days
        let noun = kind == .expiry ? "Expires" : "Due"
        if n < 0 { return kind == .expiry ? "Expired" : "Overdue" }
        if n == 0 { return "\(noun) today" }
        if n == 1 { return "\(noun) tomorrow" }
        return "\(noun) in \(n) days"
    }
}

/// A minimal wrapping layout for tag chips (family-scale counts, no scrolling required).
struct FlexibleWrap<Data: RandomAccessCollection, Content: View>: View where Data.Element: Hashable {
    let data: Data
    let spacing: CGFloat
    let content: (Data.Element) -> Content

    init(_ data: Data, spacing: CGFloat = 6, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        WrapLayout(spacing: spacing) {
            ForEach(Array(data), id: \.self) { content($0) }
        }
    }
}

/// Left-to-right wrapping `Layout`.
private struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalWidth = max(totalWidth, rowWidth - spacing)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth - spacing)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxX = bounds.maxX
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
