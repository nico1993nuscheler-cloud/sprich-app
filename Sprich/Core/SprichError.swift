import Foundation

/// All Sprich-specific errors.
enum SprichError: LocalizedError {
    case missingAPIKey(String)
    case invalidURL
    case networkError(String)
    case apiError(Int, String)
    case rateLimited(provider: String, retryAfter: TimeInterval?, dashboardURL: String)
    case emptyTranscription
    case emptyLLMResponse
    case recordingFailed(String)
    case permissionDenied(String)

    var errorDescription: String? { userFacingMessage }

    var userFacingMessage: String {
        switch self {
        case .missingAPIKey(let provider):
            return "API key for \(provider) not configured. Open Settings to add it."
        case .invalidURL:
            return "Invalid API URL. Please check your settings."
        case .networkError(let detail):
            return "Network error: \(detail)"
        case .apiError(let code, _):
            // Never surface the raw response body to the user — it can leak
            // request metadata (model, account hints). Log it via redactForLog
            // in DEBUG only; show a generic friendly message.
            if code == 401 {
                return "Invalid API key. Please check your key in Settings."
            } else if code == 402 {
                return "Billing issue with the provider. Check your account credits or payment method."
            } else if code == 503 {
                return "The provider is temporarily unavailable. Please try again in a moment."
            } else if (500...599).contains(code) {
                return "The provider returned a server error (\(code)). Please try again."
            } else {
                return "Request failed (\(code)). Please try again or check your API key."
            }
        case .rateLimited(let provider, let retryAfter, let dashboardURL):
            let waitHint: String = {
                guard let s = retryAfter else { return "Please wait a moment" }
                if s < 60 { return "Try again in \(Int(s.rounded(.up)))s" }
                let m = Int((s / 60).rounded(.up))
                return "Try again in ~\(m) min"
            }()
            return "\(provider) rate limit reached. \(waitHint), or upgrade your account at \(dashboardURL)."
        case .emptyTranscription:
            return "No speech detected. Try speaking louder or closer to the microphone."
        case .emptyLLMResponse:
            return "LLM returned empty response. Try again."
        case .recordingFailed(let detail):
            return "Recording failed: \(detail)"
        case .permissionDenied(let permission):
            return "\(permission) permission denied. Open System Settings to grant access."
        }
    }
}
