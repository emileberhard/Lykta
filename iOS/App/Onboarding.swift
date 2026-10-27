import LyktaCore
import SwiftUI
import UIKit

struct Onboarding: View {
    private enum Step {
        case welcome, notifications, connect, prompts
    }

    let model: Model
    @State private var step = Step.welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch step {
            case .welcome:
                Welcome { show(asksForNotifications ? .notifications : .connect) }
                    .transition(pageTransition)
            case .notifications:
                Notifications(model: model) { show(.connect) }
                    .transition(pageTransition)
            case .connect:
                Connect(model: model, next: { show(.prompts) }, later: finish)
                    .transition(pageTransition)
            case .prompts:
                Prompts(done: finish)
                    .transition(pageTransition)
            }
        }
        .task { await model.loadExamples() }
    }

    private var asksForNotifications: Bool {
        model.notifications.map { $0.authorization == .notDetermined } ?? true
    }

    private var pageTransition: AnyTransition {
        reduceMotion ? .opacity : .push(from: .trailing)
    }

    private func show(_ next: Step) {
        withAnimation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.5)) { step = next }
    }

    private func finish() {
        model.finishOnboarding()
    }
}

private struct Page<Content: View, Actions: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            content
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 12) { actions }
                .controlSize(.large)
                .buttonSizing(.flexible)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
    }
}

private struct Title: View {
    let text: LocalizedStringKey

    init(_ text: LocalizedStringKey) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.isHeader)
    }
}

private extension View {
    func entrance(_ isShown: Bool, order: Int, reduceMotion: Bool) -> some View {
        opacity(isShown ? 1 : 0)
            .offset(y: isShown || reduceMotion ? 0 : 16)
            .animation(.smooth(duration: 0.7).delay(reduceMotion ? 0 : 0.35 + Double(order) * 0.09), value: isShown)
    }
}

private struct Welcome: View {
    private struct Feature: Identifiable {
        let symbol: String
        let color: Color
        let title: LocalizedStringKey
        let detail: LocalizedStringKey

        var id: String { symbol }
    }

    private static let features = [
        Feature(symbol: "platter.filled.bottom.iphone", color: Color(red: 0.184, green: 0.482, blue: 1), title: "Live Activities",
                detail: "Builds, deploys and questions, live on the Lock Screen and in the Dynamic Island."),
        Feature(symbol: "widget.small", color: Color(red: 1, green: 0.690, blue: 0.125), title: "Widgets",
                detail: "Your agents’ status, always on the Home Screen."),
        Feature(symbol: "bell.badge.fill", color: Color(red: 1, green: 0.310, blue: 0.545), title: "Notifications",
                detail: "The moment a job finishes or needs you."),
    ]

    let next: () -> Void
    @State private var isShown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Page {
            VStack(spacing: 40) {
                VStack(spacing: 28) {
                    ZStack {
                        Lights(separation: 0)
                            .blur(radius: 30)
                            .scaleEffect(1.25)
                            .opacity(isShown ? 0.6 : 0)
                            .animation(.smooth(duration: 1.6).delay(reduceMotion ? 0 : 0.7), value: isShown)
                        Lights(separation: isShown || reduceMotion ? 0 : 1)
                            .opacity(isShown ? 1 : 0)
                            .animation(reduceMotion ? .easeOut(duration: 0.4) : .spring(duration: 1.3, bounce: 0.2), value: isShown)
                    }
                    .frame(height: 112)
                    Title("Welcome to Lykta")
                        .entrance(isShown, order: 0, reduceMotion: reduceMotion)
                }
                VStack(alignment: .leading, spacing: 26) {
                    ForEach(Array(Self.features.enumerated()), id: \.element.id) { index, feature in
                        HStack(alignment: .top, spacing: 18) {
                            Image(systemName: feature.symbol)
                                .font(.title.weight(.medium))
                                .foregroundStyle(feature.color.gradient)
                                .frame(width: 44)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title)
                                    .font(.headline)
                                Text(feature.detail)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                        .entrance(isShown, order: index + 2, reduceMotion: reduceMotion)
                    }
                }
            }
        } actions: {
            Button(action: next) {
                Text("Continue").fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .entrance(isShown, order: 5, reduceMotion: reduceMotion)
        }
        .task {
            guard (try? await Task.sleep(for: .seconds(0.3))) != nil else { return }
            isShown = true
        }
    }
}

private struct Notifications: View {
    let model: Model
    let next: () -> Void
    @State private var isShown = false
    @State private var isAsking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Page {
            VStack(spacing: 32) {
                Title("Know the Moment It’s Done")
                VStack(spacing: 8) {
                    ForEach(Array(model.notificationExamples.enumerated()), id: \.element.id) { index, example in
                        NotificationBanner(example: example)
                            .padding(14)
                            .glassEffect(.regular, in: .rect(cornerRadius: 26))
                            .opacity(isShown ? 1 : 0)
                            .scaleEffect(isShown || reduceMotion ? 1 : 0.92, anchor: .top)
                            .offset(y: isShown || reduceMotion ? 0 : -28)
                            .animation(reduceMotion ? .easeOut(duration: 0.3) : .spring(duration: 0.55, bounce: 0.22).delay(0.45 + Double(index) * 0.4),
                                       value: isShown)
                    }
                }
                .padding(10)
                .background {
                    LockScreenWallpaper()
                        .clipShape(.rect(cornerRadius: 36))
                }
                .environment(\.colorScheme, .dark)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Example notifications")
            }
        } actions: {
            Button {
                isAsking = true
                Task {
                    await model.allowNotifications()
                    next()
                }
            } label: {
                Text("Continue").fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .disabled(isAsking)
        }
        .task { isShown = true }
        .onChange(of: model.notifications?.authorization) { _, authorization in
            if isAsking, authorization != .notDetermined {
                next()
            }
        }
    }
}

private struct LockScreenWallpaper: View {
    var body: some View {
        MeshGradient(width: 3, height: 3, points: [
            [0, 0], [0.5, 0], [1, 0],
            [0, 0.45], [0.55, 0.5], [1, 0.4],
            [0, 1], [0.45, 1], [1, 1],
        ], colors: [
            Color(red: 0.05, green: 0.06, blue: 0.22), Color(red: 0.10, green: 0.20, blue: 0.62), Color(red: 0.03, green: 0.04, blue: 0.14),
            Color(red: 0.50, green: 0.10, blue: 0.32), Color(red: 0.22, green: 0.10, blue: 0.38), Color(red: 0.08, green: 0.22, blue: 0.66),
            Color(red: 0.62, green: 0.36, blue: 0.06), Color(red: 0.42, green: 0.08, blue: 0.26), Color(red: 0.02, green: 0.02, blue: 0.07),
        ])
        .accessibilityHidden(true)
    }
}

private struct Connect: View {
    private enum Progress {
        case ready, copied, waiting
    }

    let model: Model
    let next: () -> Void
    let later: () -> Void
    @State private var progress = Progress.ready
    @State private var copies = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isConnected = model.isAgentConnected
        Page {
            VStack(spacing: 30) {
                Connection(state: isConnected ? .connected : progress == .ready ? .idle : .flowing)
                VStack(spacing: 12) {
                    Title(isConnected ? "Your Agent Is Connected" : "Connect Your Agent")
                        .id(isConnected)
                        .transition(.blurReplace)
                    Text(isConnected ? "It just said hello on this iPhone." : "Paste the setup into Claude Code, Codex or any agent that runs commands.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .id(isConnected)
                        .transition(.blurReplace)
                }
                Arrival(model: model, isWaiting: progress != .ready)
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.6), value: isConnected)
            .animation(.smooth(duration: 0.4), value: progress)
        } actions: {
            Button {
                if isConnected {
                    next()
                } else {
                    copy()
                }
            } label: {
                ZStack {
                    Group {
                        if isConnected {
                            Text("Continue")
                        } else {
                            switch progress {
                            case .ready: Label("Copy Setup", systemImage: "doc.on.doc")
                            case .copied: Label("Copied", systemImage: "checkmark")
                            case .waiting: Label { Text("Waiting for Your Agent") } icon: { ProgressView() }
                            }
                        }
                    }
                    .transition(.blurReplace)
                }
                .fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
            .disabled(!isConnected && (progress != .ready || !model.phase.isReady))
            .animation(.smooth(duration: 0.35), value: progress)
            .animation(.smooth(duration: 0.35), value: isConnected)
            Button("Copy Again", action: copy)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .shown(!isConnected && progress == .waiting)
                .animation(.easeOut(duration: 0.2), value: progress)
        }
        .safeAreaBar(edge: .top) {
            Button("Set Up Later", action: later)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                .shown(!isConnected)
                .animation(.easeOut(duration: 0.2), value: isConnected)
        }
        .sensoryFeedback(.success, trigger: copies)
        .sensoryFeedback(.success, trigger: isConnected) { !$0 && $1 }
        .onChange(of: isConnected) { _, isConnected in
            guard isConnected else { return }
            AccessibilityNotification.Announcement("Your agent is connected").post()
        }
        .task(id: progress) {
            guard progress == .copied, (try? await Task.sleep(for: .seconds(1.1))) != nil else { return }
            progress = .waiting
        }
    }

    private func copy() {
        Task {
            guard await model.copySetup() else { return }
            copies += 1
            if progress == .ready {
                progress = .copied
            }
        }
    }
}

private struct Connection: View {
    enum State {
        case idle, flowing, connected
    }

    let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "laptopcomputer")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(.secondary)
            ZStack {
                Flow(isFlowing: state == .flowing && !reduceMotion)
                    .opacity(state == .connected ? 0 : 1)
                Capsule()
                    .fill(.green)
                    .frame(height: 3)
                    .scaleEffect(x: state == .connected ? 1 : 0, anchor: .leading)
            }
            .frame(width: 84, height: 4)
            Image(systemName: "iphone")
                .font(.system(size: 50, weight: .light))
                .foregroundStyle(state == .connected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .symbolEffect(.bounce, value: state == .connected)
                .overlay(alignment: .bottomTrailing) {
                    if state == .connected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .green)
                            .background(Circle().fill(Color(.systemBackground)).padding(2))
                            .offset(x: 10, y: 6)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.3) : .spring(duration: 0.6, bounce: 0.3), value: state)
        .padding(.top, 8)
        .accessibilityHidden(true)
    }
}

private struct Flow: View {
    let isFlowing: Bool
    @State private var phase = 0.0

    var body: some View {
        Dots(phase: phase)
            .task(id: isFlowing) {
                phase = 0
                guard isFlowing else { return }
                withAnimation(.linear(duration: 0.7).repeatForever(autoreverses: false)) { phase = 10 }
            }
    }
}

@Animatable
private struct Dots: View {
    var phase: Double

    var body: some View {
        Canvas { context, size in
            var line = Path()
            line.move(to: CGPoint(x: 2, y: size.height / 2))
            line.addLine(to: CGPoint(x: size.width - 2, y: size.height / 2))
            context.stroke(line, with: .style(.secondary), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [0.1, 10], dashPhase: -phase))
        }
    }
}

private struct Arrival: View {
    let model: Model
    let isWaiting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if model.isAgentConnected {
                if let activity = model.agentActivity {
                    LockScreenCard(state: activity.content, activity: activity.attributes.id, isStale: activity.state == .stale)
                        .background(activity.content.layout?.background?.value ?? Color(.secondarySystemBackground))
                        .clipShape(.rect(cornerRadius: 24))
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .scale(scale: 0.9).combined(with: .opacity).combined(with: .offset(y: -24)),
                            removal: .opacity))
                }
            } else {
                switch model.phase {
                case .unconfigured:
                    Problem("Set LYKTA_GATEWAY_HOST in iOS/Config/Local.xcconfig to build Lykta for a gateway.")
                case let .failed(message):
                    Notice(Problem(message), action: "Try Again") { model.start() }
                case .connecting, .ready:
                    Slot(isWaiting: isWaiting)
                        .transition(.opacity.animation(.easeOut(duration: 0.15)))
                }
            }
        }
        .frame(minHeight: 96)
    }
}

private struct Slot: View {
    let isWaiting: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 6]))
            .foregroundStyle(.tertiary)
            .background {
                if isWaiting && !reduceMotion {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.accentColor.gradient)
                        .phaseAnimator([0.03, 0.11]) { glow, opacity in
                            glow.opacity(opacity)
                        } animation: { _ in
                            .easeInOut(duration: 1.4)
                        }
                        .transition(.opacity)
                }
            }
            .frame(height: 96)
            .overlay {
                Label("Your agent’s hello appears here", systemImage: "platter.filled.bottom.iphone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
            }
            .animation(.smooth(duration: 0.6), value: isWaiting)
    }
}

private struct Prompts: View {
    private static let prompts: [LocalizedStringResource] = [
        "Show my build’s progress on my Lock Screen",
        "Tell me when the tests finish",
        "Put my open pull requests in a widget",
        "Ask me before you deploy",
    ]

    let done: () -> Void
    @State private var copied: Int?

    var body: some View {
        Page {
            VStack(spacing: 28) {
                VStack(spacing: 12) {
                    Title("Ask Your Agent")
                    Text("Copy a request, paste it into your agent and watch this iPhone.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                VStack(spacing: 0) {
                    ForEach(Array(Self.prompts.enumerated()), id: \.offset) { index, prompt in
                        if index > 0 {
                            Divider().padding(.leading, 18)
                        }
                        Button {
                            UIPasteboard.general.string = String(localized: prompt)
                            copied = index
                            AccessibilityNotification.Announcement("Copied").post()
                        } label: {
                            HStack(spacing: 12) {
                                Text("“\(Text(prompt))”")
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: copied == index ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(copied == index ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                                    .contentTransition(.symbolEffect(.replace))
                                    .accessibilityHidden(true)
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 14)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Copies the request")
                    }
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 24))
            }
        } actions: {
            Button(action: done) {
                Text("Done").fontWeight(.semibold)
            }
            .buttonStyle(.glassProminent)
        }
        .sensoryFeedback(.success, trigger: copied) { $1 != nil }
        .task(id: copied) {
            guard copied != nil, (try? await Task.sleep(for: .seconds(1.5))) != nil else { return }
            copied = nil
        }
        .animation(.snappy(duration: 0.25), value: copied)
    }
}

#if DEBUG
#Preview("Onboarding") {
    @Previewable @State var model = Model.preview(.ready)
    Onboarding(model: model)
}

#Preview("Connect", traits: .modifier(BundledExamples())) {
    @Previewable @Environment(Model.self) var model
    Connect(model: model, next: {}, later: {})
}
#endif
