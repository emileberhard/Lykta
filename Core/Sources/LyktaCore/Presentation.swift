enum Presentation {
    case activity(String)
    case widget(WidgetLayout.Family)
    case widgetBackground
    case avatar

    init(_ codingPath: [any CodingKey]) {
        let root = codingPath.first?.stringValue ?? ""
        if codingPath.prefix(2).map(\.stringValue) == ["sender", "avatar"] {
            self = .avatar
        } else if let family = WidgetLayout.Family(rawValue: root) {
            self = .widget(family)
        } else if root == "background" {
            self = .widgetBackground
        } else {
            self = .activity(root)
        }
    }

    func refusal(of feature: String) -> String? {
        switch (self, feature) {
        case (.widget(.accessoryCircular), "accessoryBackground"), (.widget(.accessoryRectangular), "accessoryBackground"): nil
        case (_, "accessoryBackground"): "accessoryBackground works only in accessoryCircular and accessoryRectangular"
        case (.widget, "privacySensitive"): nil
        case (_, "privacySensitive"): "privacySensitive works only in a widget's presentations"
        case (.avatar, _): nil
        case let (.activity(root), _):
            ["lockScreen", "expanded"].contains(root) ? nil : "links, buttons and toggles work only in lockScreen and expanded"
        case (.widget(.accessoryInline), "button"), (.widget(.accessoryInline), "toggle"):
            "buttons and toggles work only in systemSmall, systemMedium, systemLarge, accessoryCircular and accessoryRectangular"
        case (.widgetBackground, _):
            "a widget's background takes no links, buttons or toggles"
        case let (.widget(family), "link"):
            family.takesLinks ? nil : "links work only in systemSmall, systemMedium, systemLarge and accessoryRectangular; use the widget's link"
        case (.widget, _): nil
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
