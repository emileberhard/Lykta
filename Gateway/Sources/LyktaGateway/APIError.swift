struct APIError: Error, Encodable, Sendable {
    enum Code: String, Encodable, Sendable {
        case invalidRequest = "invalid_request"
        case invalidName = "invalid_name"
        case invalidLayout = "invalid_layout"
        case unsupportedEnvironment = "unsupported_environment"
        case unauthorized
        case registrationClosed = "registration_closed"
        case registrationRefused = "registration_refused"
        case notFound = "not_found"
        case conflict
        case deviceNotReady = "device_not_ready"
        case tooManyActivities = "too_many_activities"
        case payloadTooLarge = "payload_too_large"
        case appUpdateRequired = "app_update_required"
        case notificationsNotAllowed = "notifications_not_allowed"
        case notificationsNotSetUp = "notifications_not_set_up"
        case tooManyNotifications = "too_many_notifications"
        case unsupportedMedia = "unsupported_media"
        case `internal`

        var status: Int {
            switch self {
            case .invalidRequest, .invalidName, .invalidLayout, .unsupportedEnvironment: 400
            case .unauthorized: 401
            case .registrationClosed, .registrationRefused: 403
            case .notFound: 404
            case .deviceNotReady, .tooManyActivities, .conflict, .appUpdateRequired, .notificationsNotAllowed, .notificationsNotSetUp: 409
            case .payloadTooLarge: 413
            case .unsupportedMedia: 415
            case .tooManyNotifications: 429
            case .internal: 500
            }
        }
    }

    let code: Code
    let message: String
    var retryAfter: Int?

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case code = "error", message
    }
}
