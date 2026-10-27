import LyktaCore
import SwiftUI

struct WidgetExampleView: View {
    let example: WidgetExample
    let model: Model

    var body: some View {
        List {
            Section {
                WidgetPreview(layout: example.layout)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Add the Lykta widget to your Home Screen and choose “\(example.title)”.")
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
            ActionButton(title: "Send Widget", systemImage: "square.and.arrow.up.on.square", done: "Sent") {
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

struct WidgetPreview: View {
    static let side: CGFloat = 170
    static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    let layout: WidgetLayout

    var body: some View {
        WidgetView(layout: layout, family: .systemSmall, isStale: false)
            .padding(16)
            .frame(width: Self.side, height: Self.side)
            .background { WidgetBackground(background: layout.background, isStale: false) }
            .clipShape(Self.shape)
            .dynamicTypeSize(LockScreenCard.textSizes)
    }
}
