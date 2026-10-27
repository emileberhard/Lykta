public enum Surface: Sendable {
    case activity
    case widget

    var nodeKeys: Set<String> {
        switch self {
        case .activity: Layout.nodeKeys
        case .widget: WidgetLayout.nodeKeys
        }
    }

    func validate(_ json: [UInt8]) throws(LayoutError) {
        switch self {
        case .activity: _ = try Layout(json: json)
        case .widget: _ = try WidgetLayout(json: json)
        }
    }
}
