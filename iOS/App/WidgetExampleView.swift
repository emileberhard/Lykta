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
    static let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)

    let layout: WidgetLayout
    let family: WidgetLayout.Family

    var body: some View {
        if family.isAccessory {
            WidgetView(layout: layout, family: family, widget: nil, isStale: false)
                .frame(width: family.size.width, height: family.size.height)
                .foregroundStyle(.white)
                .grayscale(1)
                .padding(12)
                .background(LinearGradient(colors: [.indigo, .black], startPoint: .top, endPoint: .bottom), in: Self.shape)
                .environment(\.colorScheme, .dark)
                .environment(\.widgetRenderingMode, .vibrant)
                .dynamicTypeSize(LockScreenCard.textSizes)
        } else {
            WidgetView(layout: layout, family: family, widget: nil, isStale: false)
                .padding(16)
                .frame(width: family.size.width, height: family.size.height)
                .background { WidgetBackground(background: layout.background, isStale: false) }
                .clipShape(Self.shape)
                .dynamicTypeSize(LockScreenCard.textSizes)
        }
    }
}

extension WidgetLayout.Family {
    var size: CGSize {
        switch self {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        case .accessoryCircular: CGSize(width: 76, height: 76)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 234, height: 26)
        }
    }
}
