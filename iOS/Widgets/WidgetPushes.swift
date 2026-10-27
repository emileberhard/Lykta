import LyktaCore
import WidgetKit

nonisolated struct WidgetPushes: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        let token = PushToken(pushInfo.token)
        WidgetPushToken.save(token)
        let report = WidgetReport(pushToken: token, layoutVersion: Layout.version, places: WidgetSelection.places(in: widgets))
        Task {
            guard let gateway = GatewayClient.configured(timeout: 10), let credential = try? KeychainItem.widget.load() else { return }
            try? await gateway.report(report, widgetToken: credential.widgetToken)
        }
    }
}
