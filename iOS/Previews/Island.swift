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
    let regions: LyktaCore.Layout.Expanded?
    let keyline: Color?

    var body: some View {
        let capped = CappedHeight(maximum: LockScreenCard.maximumHeight, measurement: .proposedWidth)
        capped {
            ExpandedRegions(regions: regions)
        }
        .modifier(Island(cornerRadius: 44, keyline: keyline))
        .dynamicTypeSize(LockScreenCard.textSizes)
        .presentation("Expanded Dynamic Island")
    }
}

struct ExpandedRegions: View {
    let regions: LyktaCore.Layout.Expanded?

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                IslandRegion(node: regions?.leading)
                    .layoutPriority(1)
                VStack(spacing: 0) {
                    Color.clear.frame(height: 20)
                    IslandRegion(node: regions?.center)
                }
                .frame(maxWidth: .infinity)
                IslandRegion(node: regions?.trailing)
                    .layoutPriority(1)
            }
            IslandRegion(node: regions?.bottom)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .top)
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
