import Foundation
import LyktaCore
import WidgetKit

nonisolated struct WidgetPushes: WidgetPushHandler {
    func pushTokenDidChange(_ pushInfo: WidgetPushInfo, widgets: [WidgetInfo]) {
        Task {
            guard let gateway = GatewayClient.configured(timeout: 10), let credential = try? KeychainItem.widget.load(),
                  let report = try? await WidgetReports.make(pushToken: PushToken(pushInfo.token), places: WidgetSelection.places(in: widgets), at: .now)
            else { return }
            try? await gateway.report(report, widgetToken: credential.widgetToken)
        }
    }
}
