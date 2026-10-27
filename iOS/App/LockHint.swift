import SwiftUI

struct LockHint: View {
    private enum Step: CaseIterable {
        case open, pressed, locked
    }

    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isShown = false

    var body: some View {
        PhaseAnimator(reduceMotion ? [.locked] : Step.allCases) { step in
            ZStack {
                VStack(spacing: 24) {
                    Spacer()
                    Image(systemName: step == .locked ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 76, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .scaleEffect(step == .pressed ? 0.92 : 1)
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
                .scaleEffect(isShown || reduceMotion ? 1 : 0.94)
                if verticalSizeClass == .regular {
                    SideButtonGlow(isLit: reduceMotion || step == .pressed)
                }
            }
        } animation: { step in
            switch step {
            case .open: .smooth(duration: 0.4).delay(1.2)
            case .pressed: .snappy(duration: 0.2).delay(0.9)
            case .locked: .bouncy(duration: 0.4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.regularMaterial)
                .ignoresSafeArea()
        }
        .contentShape(.rect)
        .onTapGesture(perform: dismiss)
        .onAppear {
            withAnimation(.smooth(duration: 0.45)) { isShown = true }
        }
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }
}

private struct SideButtonGlow: View {
    let isLit: Bool

    var body: some View {
        GeometryReader { geometry in
            Capsule()
                .fill(.white)
                .frame(width: 6, height: geometry.size.height * 0.1)
                .shadow(color: .white.opacity(isLit ? 0.9 : 0), radius: 12)
                .opacity(isLit ? 1 : 0.35)
                .offset(x: isLit ? -2 : 0)
                .position(x: geometry.size.width, y: geometry.size.height * 0.27)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

#Preview {
    LockHint {}
}
