import LyktaCore
import SwiftUI

struct CompactIsland: View {
    private static let width: CGFloat = 52.33

    let leading: Node?
    let trailing: Node?
    let keyline: Color?

    var body: some View {
        HStack(spacing: 0) {
            IslandRegion(node: leading)
                .compact()
                .frame(maxWidth: Self.width, alignment: .leading)
            Spacer(minLength: Island.sensor)
            IslandRegion(node: trailing)
                .compact()
                .frame(maxWidth: Self.width, alignment: .trailing)
        }
        .fixedSize()
        .padding(.leading, 7)
        .padding(.trailing, 17)
        .frame(height: Island.height)
        .modifier(Island(cornerRadius: Island.height / 2, keyline: keyline))
        .dynamicTypeSize(.large)
        .presentation("Compact Dynamic Island")
    }
}

struct ExpandedIsland: View {
    private static let visibleHeight: CGFloat = 147

    let regions: LyktaCore.Layout.Expanded?
    let keyline: Color?

    var body: some View {
        ExpandedRegions(regions: regions, maximumHeight: LockScreenCard.maximumHeight)
            .mask(alignment: .top) {
                Rectangle().frame(height: Self.visibleHeight)
            }
            .modifier(Island(cornerRadius: 44, keyline: keyline))
            .dynamicTypeSize(LockScreenCard.textSizes)
            .presentation("Expanded Dynamic Island")
    }
}

struct ExpandedRegions: View {
    let regions: LyktaCore.Layout.Expanded?
    let maximumHeight: CGFloat

    var body: some View {
        ExpandedLayout(maximumHeight: maximumHeight) {
            if let node = regions?.leading {
                IslandRegion(node: node).layoutValue(key: ExpandedRegion.self, value: .leading)
            }
            if let node = regions?.trailing {
                IslandRegion(node: node).layoutValue(key: ExpandedRegion.self, value: .trailing)
            }
            if let node = regions?.center {
                IslandRegion(node: node).layoutValue(key: ExpandedRegion.self, value: .center)
            }
            if let node = regions?.bottom {
                IslandRegion(node: node).layoutValue(key: ExpandedRegion.self, value: .bottom)
            }
        }
    }
}

private nonisolated enum ExpandedRegion: LayoutValueKey {
    case leading, trailing, center, bottom

    static let defaultValue: ExpandedRegion? = nil
}

private struct ExpandedLayout: SwiftUI.Layout {
    private static let margin: CGFloat = 18
    private static let besideCamera: CGFloat = 120
    private static let minimumHeight: CGFloat = 84

    let maximumHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        return CGSize(width: width, height: fitted(width: width, subviews: subviews).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, fitted(width: bounds.width, subviews: subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func fitted(width: CGFloat, subviews: Subviews) -> (height: CGFloat, frames: [CGRect]) {
        let natural = frames(width: width, subviews: subviews, belowCamera: nil)
        let contentHeight = (natural.map(\.maxY).max() ?? 0) + Self.margin
        let height = min(max(contentHeight, Self.minimumHeight), maximumHeight)
        guard height != contentHeight else { return (height, natural) }
        return (height, frames(width: width, subviews: subviews, belowCamera: height - Self.margin - Island.height))
    }

    private func frames(width: CGFloat, subviews: Subviews, belowCamera: CGFloat?) -> [CGRect] {
        let inner = width - 2 * Self.margin
        let index = { (region: ExpandedRegion) in subviews.firstIndex { $0[ExpandedRegion.self] == region } }
        let spacing = { (above: Int, below: Int, axis: Axis) in subviews[above].spacing.distance(to: subviews[below].spacing, along: axis) }
        let center = index(.center)
        let leading = index(.leading)
        let trailing = index(.trailing)
        let sides = [leading, trailing].compactMap(\.self)
        var offered = Array(repeating: inner, count: subviews.count)
        var sizes = Array(repeating: CGSize.zero, count: subviews.count)
        let measure = { (member: Int, height: CGFloat?) in
            sizes[member] = subviews[member].sizeThatFits(ProposedViewSize(width: offered[member], height: height))
        }
        if let center {
            offered[center] = subviews[center].sizeThatFits(ProposedViewSize(width: inner, height: nil)).width
        }
        let rowWidth = if let leading, let trailing { (inner - spacing(leading, trailing, .horizontal)) / 2 } else { inner }
        var moved: [Int] = []
        for side in sides {
            let wanted = subviews[side].sizeThatFits(ProposedViewSize(width: .infinity, height: nil)).width
            let slot = center.map { (width - offered[$0]) / 2 - Self.margin - spacing(side, $0, .horizontal) }
            if wanted <= min(Self.besideCamera, slot ?? .infinity) {
                offered[side] = wanted
                measure(side, nil)
            } else {
                offered[side] = min(wanted, rowWidth)
                moved.append(side)
            }
        }
        let rows = [center.map { [$0] }, moved.isEmpty ? nil : moved, index(.bottom).map { [$0] }].compactMap(\.self)
        if let belowCamera {
            let gaps = zip(rows, rows.dropFirst()).map { above, below in
                above.flatMap { a in below.map { spacing(a, $0, .vertical) } }.max() ?? 0
            }
            let flexibility = rows.map { row in
                row.map { member in
                    subviews[member].sizeThatFits(ProposedViewSize(width: offered[member], height: .infinity)).height
                        - subviews[member].sizeThatFits(ProposedViewSize(width: offered[member], height: 0)).height
                }.max() ?? 0
            }
            var remaining = belowCamera - gaps.reduce(0, +)
            for (placed, row) in rows.indices.sorted(by: { flexibility[$0] < flexibility[$1] }).enumerated() {
                let offer = max(remaining / CGFloat(rows.count - placed), 0)
                rows[row].forEach { measure($0, offer) }
                remaining -= rows[row].map { sizes[$0].height }.max() ?? 0
            }
        } else {
            rows.joined().forEach { measure($0, nil) }
        }
        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        let place = { (member: Int, top: CGFloat) in
            let x = switch subviews[member][ExpandedRegion.self] {
            case .leading?: Self.margin
            case .trailing?: width - Self.margin - sizes[member].width
            default: (width - sizes[member].width) / 2
            }
            frames[member] = CGRect(origin: CGPoint(x: x, y: top), size: sizes[member])
        }
        for side in sides where !moved.contains(side) {
            place(side, Self.margin)
        }
        if let center {
            place(center, Island.height)
        }
        for side in moved {
            place(side, center.map { frames[$0].maxY + spacing($0, side, .vertical) } ?? Island.height)
        }
        if let bottom = index(.bottom) {
            place(bottom, subviews.indices.filter { $0 != bottom }.map { frames[$0].maxY + spacing($0, bottom, .vertical) }.reduce(Island.height, max))
        }
        return frames
    }
}

struct MinimalIsland: View {
    let node: Node?
    let keyline: Color?

    var body: some View {
        Color.clear
            .frame(width: Island.camera, height: Island.height)
            .modifier(Island(cornerRadius: Island.height / 2, keyline: nil))
            .overlay(alignment: .trailing) {
                MinimalBubble(node: node, keyline: keyline)
                    .alignmentGuide(.trailing) { $0[.leading] - 8 }
            }
            .frame(maxWidth: .infinity)
            .presentation("Minimal Dynamic Island")
    }
}

struct MinimalBubble: View {
    let node: Node?
    let keyline: Color?

    var body: some View {
        IslandRegion(node: node)
            .compact()
            .frame(minWidth: Island.height, maxWidth: 45, minHeight: Island.height, maxHeight: Island.height)
            .modifier(Island(cornerRadius: Island.height / 2, keyline: keyline))
            .dynamicTypeSize(.large)
    }
}

private struct IslandRegion: View {
    let node: Node?

    var body: some View {
        Root(node: node, target: nil, isStale: false)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
    }
}

private struct Island: ViewModifier {
    static let height: CGFloat = 36.67
    static let camera: CGFloat = 120
    static let sensor: CGFloat = 95

    let cornerRadius: CGFloat
    let keyline: Color?
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .background {
                shape
                    .fill(.black)
                    .overlay {
                        if colorScheme == .dark {
                            shape.strokeBorder(keyline?.opacity(0.6) ?? Color(.separator), lineWidth: 1)
                        }
                    }
            }
    }
}

private extension View {
    func presentation(_ name: LocalizedStringKey) -> some View {
        accessibilityElement(children: .combine)
            .accessibilityRemoveTraits(.isButton)
            .accessibilityLabel { label in
                Text(name)
                label
            }
    }
}
