import Foundation

/// Bounded Google error parsing maps only recognized categories. Server text,
/// addresses, project identifiers, credential URLs and response bodies never
/// enter errors, usage events or saved source artifacts.
enum EarthGoogleErrorResponse
{
    static let maximumBytes = 64 * 1024

    static func failure(statusCode: Int, data: Data) -> EarthCaptureError
    {
        let json = data.count <= maximumBytes ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] : nil
        let error = json?["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]] ?? []
        let legacy = error?["errors"] as? [[String: Any]] ?? []
        let reasons = (details + legacy).compactMap { $0["reason"] as? String }
        for reason in reasons
        {
            let category: EarthServiceRejection?
            switch reason
            {
                case "API_KEY_INVALID", "API_KEY_EXPIRED", "API_KEY_NOT_FOUND": category = .invalidKey
                case "API_KEY_IP_ADDRESS_BLOCKED": category = .ipRestricted
                case "API_KEY_SERVICE_BLOCKED": category = .apiRestricted
                case "API_KEY_HTTP_REFERRER_BLOCKED", "API_KEY_ANDROID_APP_BLOCKED", "API_KEY_IOS_APP_BLOCKED": category = .applicationRestricted
                case "SERVICE_DISABLED", "accessNotConfigured": category = .apiDisabled
                case "BILLING_DISABLED", "BILLING_NOT_ACTIVE": category = .billingDisabled
                case "RATE_LIMIT_EXCEEDED", "QUOTA_EXCEEDED", "quotaExceeded", "rateLimitExceeded", "dailyLimitExceeded": category = .quotaExceeded
                default: category = nil
            }
            if let category { return .serviceRejected(reason: category, statusCode: statusCode) }
        }
        // Older Maps responses sometimes provide only an English message.
        // Recognize fixed diagnostic phrases, never display the supplied text.
        let message = (error?["message"] as? String ?? "").lowercased()
        let category: EarthServiceRejection?
        if message.contains("requests from this ip"), message.contains("blocked") { category = .ipRestricted }
        else if message.contains("api key not valid") || message.contains("missing a valid api key") { category = .invalidKey }
        else if message.contains("billing"), message.contains("disabled") || message.contains("not enabled") { category = .billingDisabled }
        else if message.contains("api"), message.contains("has not been used") || message.contains("is disabled") { category = .apiDisabled }
        else { category = nil }
        if let category { return .serviceRejected(reason: category, statusCode: statusCode) }
        if [401, 403].contains(statusCode) { return .serviceRejected(reason: .permissionDenied, statusCode: statusCode) }
        return .requestFailed(statusCode)
    }
}
