import LyktaCore
import SwiftUI

struct Gallery: View {
    struct Route: Hashable {}

    let model: Model
    @Namespace private var transition

    var body: some View {
        List(model.examples) { example in
            Section {
                NavigationLink(value: example.id) {
                    LockScreenCard(state: example.preview, activity: nil, isStale: false)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                        .contentShape(.rect)
                }
                .accessibilityLabel(example.title)
                .matchedTransitionSource(id: example.id, in: transition)
                .lockScreenRow(example.preview)
            }
        }
        .listSectionSpacing(.compact)
        .navigationLinkIndicatorVisibility(.hidden)
        .navigationTitle("Examples")
        .navigationDestination(for: Example.ID.self) { id in
            if let example = model.examples.first(where: { $0.id == id }) {
                ExampleView(example: example, model: model)
                    .navigationTransition(.zoom(sourceID: id, in: transition))
            }
        }
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
                    IslandPreview(layout: layout)
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

private struct IslandPreview: View {
    private enum Presentation: Hashable {
        case compact, expanded, minimal

        var name: LocalizedStringResource {
            switch self {
            case .compact: "Compact Dynamic Island"
            case .expanded: "Expanded Dynamic Island"
            case .minimal: "Minimal Dynamic Island"
            }
        }
    }

    private static let height: CGFloat = 36.67
    private static let camera: CGFloat = 120
    private static let compactWidth: CGFloat = 52.33

    let layout: LyktaCore.Layout
    @State private var presentation = Presentation.compact
    @Namespace private var island
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            Picker("Dynamic Island", selection: $presentation.animation(animation)) {
                Text("Compact").tag(Presentation.compact)
                Text("Expanded").tag(Presentation.expanded)
                Text("Minimal").tag(Presentation.minimal)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)

            ZStack(alignment: .top) {
                switch presentation {
                case .compact: compact
                case .expanded: expanded
                case .minimal: minimal
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .onTapGesture {
                withAnimation(animation) { presentation = presentation == .expanded ? .compact : .expanded }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(presentation.name))
        }
        .sensoryFeedback(.impact(weight: .light), trigger: presentation)
    }

    private var compact: some View {
        HStack(spacing: 0) {
            region(layout.compactLeading)
                .compact()
                .frame(maxWidth: Self.compactWidth, alignment: .leading)
            Spacer(minLength: Self.camera)
            region(layout.compactTrailing)
                .compact()
                .frame(maxWidth: Self.compactWidth, alignment: .trailing)
        }
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: Self.height)
        .island(cornerRadius: Self.height / 2, outline: outline, id: id(.compact), in: island)
    }

    private var expanded: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                region(layout.expanded?.leading)
                    .layoutPriority(1)
                VStack(spacing: 0) {
                    Color.clear.frame(height: 20)
                    region(layout.expanded?.center)
                }
                .frame(maxWidth: .infinity)
                region(layout.expanded?.trailing)
                    .layoutPriority(1)
            }
            region(layout.expanded?.bottom)
        }
        .padding(EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24))
        .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 160, alignment: .top)
        .island(cornerRadius: 44, outline: outline, id: id(.expanded), in: island)
    }

    private var minimal: some View {
        HStack(spacing: 8) {
            Color.clear
                .frame(width: Self.camera, height: Self.height)
                .island(cornerRadius: Self.height / 2, outline: idleOutline, id: id(.minimal), in: island)
            region(layout.minimal)
                .compact()
                .frame(minWidth: Self.height, maxWidth: 45, minHeight: Self.height, maxHeight: Self.height)
                .island(cornerRadius: Self.height / 2, outline: outline, id: "detached", in: island)
                .transition(.scale(scale: 0.5, anchor: .leading).combined(with: .opacity))
        }
    }

    private func region(_ node: Node?) -> some View {
        Root(node: node, activity: nil, isStale: false)
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var outline: Color? {
        colorScheme == .dark ? layout.keyline?.value.opacity(0.6) ?? idleOutline : nil
    }

    private var idleOutline: Color? {
        colorScheme == .dark ? Color(.separator) : nil
    }

    private var animation: Animation {
        reduceMotion ? .easeInOut(duration: 0.25) : .spring(duration: 0.45, bounce: 0.25)
    }

    private func id(_ presentation: Presentation) -> String {
        reduceMotion ? "\(presentation)" : "island"
    }
}

private extension View {
    func island(cornerRadius: CGFloat, outline: Color?, id: String, in namespace: Namespace.ID) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return clipShape(shape).background {
            shape
                .fill(.black)
                .overlay { if let outline { shape.strokeBorder(outline, lineWidth: 1) } }
                .matchedGeometryEffect(id: id, in: namespace)
        }
    }
}

#if DEBUG
#Preview("Examples") {
    let model = Model.preview(.ready)
    NavigationStack {
        Gallery(model: model)
    }
    .task { await model.loadExamples() }
}
#endif
