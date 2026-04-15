import Foundation

/// Multi-provider LLM service for text cleanup.
/// Supports Groq (fastest — same key as STT), Claude, Gemini, and OpenAI.
class LLMService {

    /// Ephemeral session — no on-disk URL cache, no cookies, no credential storage.
    /// Prevents API keys and prompt/response bodies from being persisted to
    /// `~/Library/Caches/<bundle>/Cache.db*`.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        return URLSession(configuration: cfg)
    }()

    private static func retryAfterSeconds(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") ?? http.value(forHTTPHeaderField: "retry-after"),
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return seconds
    }

    private static func throwIfRateLimited(
        _ http: HTTPURLResponse,
        provider: LLMProviderType
    ) throws {
        guard http.statusCode == 429 else { return }
        throw SprichError.rateLimited(
            provider: provider.displayName,
            retryAfter: retryAfterSeconds(http),
            dashboardURL: provider.dashboardURL
        )
    }

    /// Clean up transcribed text using the configured LLM provider.
    func cleanup(
        rawText: String,
        mode: TranscriptionMode,
        settings: AppSettings
    ) async throws -> String {
        let sanitizedText = InputSanitizer.sanitize(rawText)

        guard !sanitizedText.isEmpty else {
            throw SprichError.emptyTranscription
        }

        let systemPrompt = settings.promptForMode(mode)

        switch settings.llmProvider {
        case .groq:
            return try await callGroqLLM(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.groqLLMModel
            )
        case .claude:
            return try await callClaude(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.claudeModel
            )
        case .google:
            return try await callGemini(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.googleModel
            )
        case .openai:
            return try await callOpenAI(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.openAILLMModel
            )
        }
    }

    // MARK: - Groq LLM (fastest — reuses STT API key)

    private func callGroqLLM(
        systemPrompt: String,
        userMessage: String,
        model: String
    ) async throws -> String {
        // Reuse the Groq STT key — same account, same key
        guard let apiKey = KeychainManager.retrieve(key: STTProviderType.groq.keychainKey) else {
            throw SprichError.missingAPIKey("Groq")
        }

        guard let url = URL(string: "https://api.groq.com/openai/v1/chat/completions") else {
            throw SprichError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": 1024,
            "temperature": 0.3,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SprichError.networkError("Invalid response")
        }

        try Self.throwIfRateLimited(httpResponse, provider: .groq)
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SprichError.apiError(httpResponse.statusCode, errorBody)
        }

        struct GroqResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(GroqResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw SprichError.emptyLLMResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Claude (Anthropic)

    private func callClaude(
        systemPrompt: String,
        userMessage: String,
        model: String
    ) async throws -> String {
        guard let apiKey = KeychainManager.retrieve(key: LLMProviderType.claude.keychainKey) else {
            throw SprichError.missingAPIKey("Anthropic")
        }

        guard let url = URL(string: "https://api.anthropic.com/v1/messages") else {
            throw SprichError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 1024,
            "system": systemPrompt,
            "messages": [
                ["role": "user", "content": userMessage]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SprichError.networkError("Invalid response")
        }

        try Self.throwIfRateLimited(httpResponse, provider: .claude)
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SprichError.apiError(httpResponse.statusCode, errorBody)
        }

        struct ClaudeResponse: Decodable {
            struct Content: Decodable {
                let text: String
            }
            let content: [Content]
        }

        let decoded = try JSONDecoder().decode(ClaudeResponse.self, from: data)
        guard let text = decoded.content.first?.text else {
            throw SprichError.emptyLLMResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Google Gemini

    private func callGemini(
        systemPrompt: String,
        userMessage: String,
        model: String
    ) async throws -> String {
        guard let apiKey = KeychainManager.retrieve(key: LLMProviderType.google.keychainKey) else {
            throw SprichError.missingAPIKey("Google")
        }

        // Sanitize model string: only allow safe characters for URL path interpolation.
        let allowedModelChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        guard !model.isEmpty,
              model.unicodeScalars.allSatisfy({ allowedModelChars.contains($0) }) else {
            throw SprichError.invalidURL
        }

        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            throw SprichError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "system_instruction": [
                "parts": [
                    ["text": systemPrompt]
                ]
            ],
            "contents": [
                [
                    "parts": [
                        ["text": userMessage]
                    ]
                ]
            ],
            "generationConfig": [
                "maxOutputTokens": 1024,
                "temperature": 0.3,
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SprichError.networkError("Invalid response")
        }

        try Self.throwIfRateLimited(httpResponse, provider: .google)
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SprichError.apiError(httpResponse.statusCode, errorBody)
        }

        struct GeminiResponse: Decodable {
            struct Candidate: Decodable {
                struct Content: Decodable {
                    struct Part: Decodable {
                        let text: String?
                    }
                    let parts: [Part]
                }
                let content: Content
            }
            let candidates: [Candidate]
        }

        let decoded = try JSONDecoder().decode(GeminiResponse.self, from: data)
        guard let text = decoded.candidates.first?.content.parts.first?.text else {
            throw SprichError.emptyLLMResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - OpenAI

    private func callOpenAI(
        systemPrompt: String,
        userMessage: String,
        model: String
    ) async throws -> String {
        guard let apiKey = KeychainManager.retrieve(key: LLMProviderType.openai.keychainKey) else {
            throw SprichError.missingAPIKey("OpenAI")
        }

        guard let url = URL(string: "https://api.openai.com/v1/chat/completions") else {
            throw SprichError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userMessage]
            ],
            "max_tokens": 1024,
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SprichError.networkError("Invalid response")
        }

        try Self.throwIfRateLimited(httpResponse, provider: .openai)
        guard httpResponse.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SprichError.apiError(httpResponse.statusCode, errorBody)
        }

        struct OpenAIResponse: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let text = decoded.choices.first?.message.content else {
            throw SprichError.emptyLLMResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
