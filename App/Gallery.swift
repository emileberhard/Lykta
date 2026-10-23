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

#if DEBUG
struct BundledExamples: PreviewModifier {
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
#endif
