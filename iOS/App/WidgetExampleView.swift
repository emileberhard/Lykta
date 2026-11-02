import LyktaCore
import SwiftUI
import WidgetKit

struct WidgetExampleView: View {
    let example: WidgetExample
    let model: Model

    var body: some View {
        List {
            Section {
                ForEach(example.families, id: \.self) { family in
                    WidgetPreview(layout: example.layout, family: family)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Color.clear)
                }
            } footer: {
                Text("Add the Lykta widget to your Home Screen or Lock Screen and choose “\(example.title)”.")
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            if let error = model.error {
                Section { Problem(error) }
            }
        }
        .listSectionSpacing(.compact)
        .navigationTitle(example.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaBar(edge: .bottom) {
            ActionButton(title: "Send Widget", systemImage: "square.and.arrow.up.on.square", working: "Sending…", done: "Sent") {
                await model.send(example)
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
