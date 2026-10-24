import LyktaCore
import SwiftUI

struct Gallery: View {
    struct Route: Hashable {}

    let model: Model
    @Namespace private var transition

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: GalleryCard.spacing) {
                Heading("Live Activities")
                ForEach(model.examples) { example in
                    GalleryCard(example: example, transition: transition)
                }
                Heading("Notifications")
                ForEach(model.notificationExamples) { example in
                    NotificationCard(example: example, transition: transition)
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
        .navigationDestination(for: NotificationExample.Route.self) { route in
            if let example = model.notificationExamples.first(where: { $0.route == route }) {
                NotificationExampleView(example: example, model: model)
                    .navigationTransition(.zoom(sourceID: route, in: transition))
            }
        }
    }
}

private struct Heading: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .padding(.top, GalleryCard.spacing)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct NotificationCard: View {
    let example: NotificationExample
    let transition: Namespace.ID

    var body: some View {
        NavigationLink(value: example.route) {
            NotificationBanner(example: example)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: GalleryCard.shape)
                .contentShape(GalleryCard.shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .matchedTransitionSource(id: example.route, in: transition) { $0.clipShape(GalleryCard.shape) }
    }
}

private struct GalleryCard: View {
    static let spacing: CGFloat = 12
    static let margin: CGFloat = 16
    static let shape = RoundedRectangle(cornerRadius: 26)

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
