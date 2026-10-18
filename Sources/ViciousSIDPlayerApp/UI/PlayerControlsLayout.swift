import SwiftUI

/// Behält zusammengehörige Controls in einer Zeile und bricht nur zwischen Gruppen um.
struct PlayerControlsLayout: Layout {
    private let horizontalSpacing: CGFloat = 10
    private let verticalSpacing: CGFloat = 8

    private struct Placement {
        var index: Int
        var origin: CGPoint
        var size: CGSize
    }

    private func arrangement(width: CGFloat, subviews: Subviews) -> (CGSize, [Placement]) {
        var sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        if let first = subviews.first {
            let minimum = first.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
            let remainder = sizes.dropFirst().reduce(0) { $0 + $1.width + horizontalSpacing }
            sizes[0].width = min(sizes[0].width, max(minimum, width - remainder))
            sizes[0].height = first.sizeThatFits(ProposedViewSize(width: sizes[0].width, height: nil)).height
        }
        var placements: [Placement] = []
        var row: [Int] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        func finishRow() {
            for index in row { placements[index].origin.y = y + (rowHeight - placements[index].size.height) / 2 }
            y += rowHeight + verticalSpacing
            row = []; x = 0; rowHeight = 0
        }
        for (index, size) in sizes.enumerated() where size.width > 0 && size.height > 0 {
            if !row.isEmpty && x + horizontalSpacing + size.width > width { finishRow() }
            if !row.isEmpty { x += horizontalSpacing }
            let originX = index == sizes.count - 1 ? max(x, width - size.width) : x
            row.append(placements.count)
            placements.append(Placement(index: index, origin: CGPoint(x: originX, y: y), size: size))
            x = originX + size.width; rowHeight = max(rowHeight, size.height)
        }
        if !row.isEmpty { finishRow() }
        return (CGSize(width: width, height: max(0, y - verticalSpacing)), placements)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width + horizontalSpacing }
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? max(0, ideal - horizontalSpacing)
        return arrangement(width: width, subviews: subviews).0
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for placement in arrangement(width: bounds.width, subviews: subviews).1 {
            subviews[placement.index].place(at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                anchor: .topLeading, proposal: ProposedViewSize(placement.size))
        }
    }
}
