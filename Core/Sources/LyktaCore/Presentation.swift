enum Presentation {
    case activity(String)
    case widget(WidgetLayout.Family)
    case widgetBackground

    init(_ codingPath: [any CodingKey]) {
        let root = codingPath.first?.stringValue ?? ""
        if let family = WidgetLayout.Family(rawValue: root) {
            self = .widget(family)
        } else if root == "background" {
            self = .widgetBackground
        } else {
            self = .activity(root)
        }
    }

    func refusal(of kind: String) -> String? {
        switch self {
        case let .activity(root):
            ["lockScreen", "expanded"].contains(root) ? nil : "links, buttons and toggles work only in lockScreen and expanded"
        case .widgetBackground:
            "a widget's background takes no links, buttons or toggles"
        case let .widget(family) where kind == "link":
            family.takesLinks ? nil : "links work only in systemSmall, systemMedium, systemLarge and accessoryRectangular; use the widget's link"
        case .widget:
            "buttons and toggles work only in Live Activities"
        }
    }
}

extension WidgetLayout.Family {
    var takesLinks: Bool {
        switch self {
        case .systemSmall, .systemMedium, .systemLarge, .accessoryRectangular: true
        case .accessoryCircular, .accessoryInline: false
        }
    }
}
