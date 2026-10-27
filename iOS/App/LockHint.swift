import SwiftUI

struct LockHint: View {
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "lock.fill")
                .font(.system(size: 76, weight: .semibold))
                .symbolEffect(.bounce, options: .repeat(.periodic(delay: 1.5)), isActive: !reduceMotion)
                .accessibilityHidden(true)
            Text("Lock to See It")
                .font(.title.bold())
                .multilineTextAlignment(.center)
            Spacer()
            Button("Not Now", action: dismiss)
                .buttonStyle(.glass)
                .controlSize(.large)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
        .overlay {
            if verticalSizeClass == .regular {
                SideButtonGlow(isPulsing: !reduceMotion)
            }
        }
        .contentShape(.rect)
        .onTapGesture(perform: dismiss)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct SideButtonGlow: View {
    let isPulsing: Bool

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.white)
                .frame(width: 6, height: geometry.size.height * 0.1)
                .shadow(color: .white, radius: 10)
                .phaseAnimator(isPulsing ? [0.35, 1] : [1]) { glow, opacity in
                    glow.opacity(opacity)
                } animation: { _ in
                    .easeInOut(duration: 0.9)
                }
                .position(x: geometry.size.width - 1, y: geometry.size.height * 0.26)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    LockHint {}
}
