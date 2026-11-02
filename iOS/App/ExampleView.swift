import LyktaCore
import SwiftUI

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
            ActionButton(title: "Start Live Activity", systemImage: "platter.filled.bottom.and.arrow.down.iphone", working: "Starting…", done: "Sent") {
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

#if DEBUG
#Preview("Example", traits: .modifier(BundledExamples())) {
    @Previewable @Environment(Model.self) var model
    NavigationStack {
        ExampleView(example: model.examples.first { $0.id == "solar-eclipse" }!, model: model)
    }
}
#endif
