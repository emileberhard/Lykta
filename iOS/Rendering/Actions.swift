import AppIntents
import LyktaCore

struct ActionSender: Sendable {
    let send: @Sendable (Action) async throws -> Void
}

struct ButtonIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Press a Live Activity button"
    static let isDiscoverable = false

    @Parameter(title: "Activity") var activity: String
    @Parameter(title: "Button") var button: String
    @Dependency private var sender: ActionSender

    init() {}

    init(activity: UUID, button: String) {
        self.activity = activity.uuidString
        self.button = button
    }

    func perform() async throws -> some IntentResult {
        try await sender.send(Action(id: UUID(), activity: activityID(activity), input: .button(button)))
        return .result()
    }
}

struct ToggleIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Switch a Live Activity toggle"
    static let isDiscoverable = false

    @Parameter(title: "Activity") var activity: String
    @Parameter(title: "Toggle") var toggle: String
    @Parameter(title: "On") var isOn: Bool
    @Dependency private var sender: ActionSender

    init() {}

    init(activity: UUID, toggle: String, isOn: Bool) {
        self.activity = activity.uuidString
        self.toggle = toggle
        self.isOn = isOn
    }

    func perform() async throws -> some IntentResult {
        try await sender.send(Action(id: UUID(), activity: activityID(activity), input: .toggle(toggle, isOn: isOn)))
        return .result()
    }
}

private func activityID(_ text: String) -> UUID {
    guard let id = UUID(uuidString: text) else { preconditionFailure("Lykta builds its intents with activity UUIDs") }
    return id
}
