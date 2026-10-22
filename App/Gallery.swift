import LyktaCore
import SwiftUI

struct Gallery: View {
    struct Route: Hashable {}

    let model: Model
    @Namespace private var transition

    var body: some View {
        ScrollView {
            VStack(spacing: GalleryCard.spacing) {
                ForEach(model.examples) { example in
                    GalleryCard(example: example, transition: transition)
                }
            }
        }
        .contentMargins(.horizontal, GalleryCard.margin, for: .scrollContent)
        .contentMargins(.vertical, GalleryCard.spacing, for: .scrollContent)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Examples")
        .navigationDestination(for: Example.ID.self) { id in
            if let example = model.examples.first(where: { $0.id == id }) {
                ExampleView(example: example, model: model)
                    .navigationTransition(.zoom(sourceID: id, in: transition))
            }
        }
    }
}

private struct GalleryCard: View {
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 16
    private static let shape = RoundedRectangle(cornerRadius: 26)

    let example: Example
    let transition: Namespace.ID

    var body: some View {
        NavigationLink(value: example.id) {
            LockScreenCard(state: example.preview, activity: nil, isStale: false)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .background(example.preview.layout?.background?.value ?? Color(.secondarySystemGroupedBackground))
                .clipShape(Self.shape)
                .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(example.title)
        .matchedTransitionSource(id: example.id, in: transition) { $0.clipShape(Self.shape) }
    }
}

struct ExampleView: View {
    let example: Example
    let model: Model

    var body: some View {
        List {
            Section {
                LockScreenCard(state: example.preview, activity: nil, isStale: false)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                    .accessibilityRemoveTraits(.isButton)
                    .lockScreenRow(example.preview)
            }
            if let layout = example.preview.layout {
                Section {
                    VStack(spacing: 24) {
                        ExpandedIsland(regions: layout.expanded, keyline: layout.keyline?.value)
                        CompactIsland(leading: layout.compactLeading, trailing: layout.compactTrailing, keyline: layout.keyline?.value)
                        MinimalIsland(node: layout.minimal, keyline: layout.keyline?.value)
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }
            if model.phase.isReady && !model.areActivitiesEnabled {
                Section { ActivitiesOffNotice() }
            }
            if let error = model.error {
                Section { Problem(error) }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(example.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .bottom) {
            ActionButton(title: "Show on Lock Screen", systemImage: "platter.filled.bottom.and.arrow.down.iphone", done: "Sent") {
                await model.show(example)
            }
            .buttonStyle(.glassProminent)
            .tint(.primary)
            .foregroundStyle(Color(.systemBackground))
            .controlSize(.large)
            .buttonSizing(.flexible)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .disabled(!model.phase.isReady)
            .padding(.horizontal)
        }
    }
}

private struct CompactIsland: View {
    private static let width: CGFloat = 52.33

    let leading: Node?
    let trailing: Node?
    let keyline: Color?

    var body: some View {
        HStack(spacing: 0) {
            IslandRegion(node: leading)
                .compact()
                .frame(maxWidth: Self.width, alignment: .leading)
            Spacer(minLength: Island.camera)
            IslandRegion(node: trailing)
                .compact()
                .frame(maxWidth: Self.width, alignment: .trailing)
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: Island.height)
        .modifier(Island(cornerRadius: Island.height / 2, keyline: keyline))
        .dynamicTypeSize(.large)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compact Dynamic Island")
    }
}

private struct ExpandedIsland: View {
    let regions: LyktaCore.Layout.Expanded?
    let keyline: Color?

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
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 160, alignment: .top)
        .modifier(Island(cornerRadius: 44, keyline: keyline))
        .dynamicTypeSize(LockScreenCard.textSizes)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Expanded Dynamic Island")
    }
}

private struct MinimalIsland: View {
    let node: Node?
    let keyline: Color?

    var body: some View {
        Color.clear
            .frame(width: Island.camera, height: Island.height)
            .modifier(Island(cornerRadius: Island.height / 2, keyline: nil))
            .overlay(alignment: .trailing) {
                IslandRegion(node: node)
                    .compact()
                    .frame(minWidth: Island.height, maxWidth: 45, minHeight: Island.height, maxHeight: Island.height)
                    .modifier(Island(cornerRadius: Island.height / 2, keyline: keyline))
                    .alignmentGuide(.trailing) { $0[.leading] - 8 }
            }
            .frame(maxWidth: .infinity)
            .dynamicTypeSize(.large)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Minimal Dynamic Island")
    }
}

private struct IslandRegion: View {
    let node: Node?

    var body: some View {
        Root(node: node, activity: nil, isStale: false)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct Island: ViewModifier {
    static let height: CGFloat = 36.67
    static let camera: CGFloat = 120

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

#if DEBUG
private struct BundledExamples: PreviewModifier {
    static func makeSharedContext() async -> Model {
        let model = Model.preview(.ready)
        await model.loadExamples()
        return model
    }

    func body(content: Content, context: Model) -> some View {
        content.environment(context)
    }
}

#Preview("Examples", traits: .modifier(BundledExamples())) {
    @Previewable @Environment(Model.self) var model
    NavigationStack {
        Gallery(model: model)
    }
}

#Preview("Example", traits: .modifier(BundledExamples())) {
    @Previewable @Environment(Model.self) var model
    NavigationStack {
        ExampleView(example: model.examples.first { $0.id == "solar-eclipse" }!, model: model)
    }
}
#endif
