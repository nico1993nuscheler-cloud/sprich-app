import Foundation

/// Multi-provider Speech-to-Text service.
/// Supports Groq Whisper, OpenAI Whisper, Deepgram Nova-3, and local
/// on-device Whisper (via WhisperKit).
class TranscriptionService {

    /// Ephemeral session — no on-disk URL cache, no cookies, no credential storage.
    /// Prevents API keys and transcript bodies from being persisted to
    /// `~/Library/Caches/<bundle>/Cache.db*`.
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        return URLSession(configuration: cfg)
    }()

    /// Shared on-device Whisper pipe. Load is expensive (~10–30 s first
    /// time), so we keep one instance for the lifetime of the process.
    static let localWhisper = LocalWhisperService()

    /// Transcribe audio data using the configured STT provider.
    func transcribe(
        audioData: Data,
        provider: STTProviderType,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        // Local STT runs entirely on-device and takes no API key — route
        // it before the key guard so .local doesn't trip `missingAPIKey`.
        if provider == .local {
            return try await Self.localWhisper.transcribe(
                audioData: audioData,
                language: language
            )
        }

        guard let apiKey = KeychainManager.retrieve(key: provider.keychainKey) else {
            throw SprichError.missingAPIKey(provider.displayName)
        }

        switch provider {
        case .groq, .openai:
            return try await transcribeWhisperCompatible(
                audioData: audioData,
                provider: provider,
                apiKey: apiKey,
                language: language,
                prompt: prompt,
                model: provider == .groq ? "whisper-large-v3" : "whisper-1"
            )
        case .deepgram:
            return try await transcribeDeepgram(
                audioData: audioData,
                provider: provider,
                apiKey: apiKey,
                language: language,
                prompt: prompt
            )
        case .local:
            // Unreachable — handled above before the keychain guard.
            throw SprichError.apiError(-1, "local path not routed correctly")
        }
    }

    /// Parse the optional `Retry-After` header (seconds) from a 429 response.
    private static func retryAfterSeconds(_ http: HTTPURLResponse) -> TimeInterval? {
        guard let raw = http.value(forHTTPHeaderField: "Retry-After") ?? http.value(forHTTPHeaderField: "retry-after"),
              let seconds = Double(raw.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return seconds
    }

    // MARK: - Whisper-Compatible (Groq + OpenAI)

    private func transcribeWhisperCompatible(
        audioData: Data,
        provider: STTProviderType,
        apiKey: String,
        language: String?,
        prompt: String?,
        model: String
    ) async throws -> String {
        guard let url = URL(string: provider.baseURL) else {
            throw SprichError.invalidURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        // Build multipart form data
        var body = Data()

        // File field
        body.appendMultipart(boundary: boundary, name: "file", filename: "audio.wav",
                            mimeType: "audio/wav", data: audioData)

        // Model field
        body.appendMultipart(boundary: boundary, name: "model", value: model)

        // Response format
        body.appendMultipart(boundary: boundary, name: "response_format", value: "json")

        // Language (optional)
        if let lang = language {
            body.appendMultipart(boundary: boundary, name: "language", value: lang)
        }

        // Prompt (optional — biases vocabulary + punctuation; Whisper limits to ~224 tokens)
        if let p = prompt, !p.isEmpty {
            let capped = String(p.prefix(800))
            body.appendMultipart(boundary: boundary, name: "prompt", value: capped)
        }

        // Close boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SprichError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SprichError.rateLimited(
                    provider: provider.displayName,
                    retryAfter: Self.retryAfterSeconds(httpResponse),
                    dashboardURL: provider.dashboardURL
                )
            }
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SprichError.apiError(httpResponse.statusCode, errorBody)
        }

        struct WhisperResponse: Decodable {
            let text: String
        }

        let decoded = try JSONDecoder().decode(WhisperResponse.self, from: data)
        return decoded.text
    }

    // MARK: - Deepgram

    private func transcribeDeepgram(
        audioData: Data,
        provider: STTProviderType,
        apiKey: String,
        language: String?,
        prompt: String?
    ) async throws -> String {
        var urlString = "https://api.deepgram.com/v1/listen?model=nova-3&smart_format=true"
        if let lang = language {
            urlString += "&language=\(lang)"
        } else {
            urlString += "&detect_language=true"
        }
        // Deepgram `keywords` param biases transcription. Take first ~30 comma-separated terms.
        if let p = prompt, !p.isEmpty {
            let terms = p.split(separator: ",").prefix(30).map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
            for term in terms {
                if let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                    urlString += "&keywords=\(encoded)"
                }
            }
        }

        guard let url = URL(string: urlString) else {
            throw SprichError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30
        request.httpBody = audioData

        let (data, response) = try await Self.session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SprichError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 429 {
                throw SprichError.rateLimited(
                    provider: provider.displayName,
                    retryAfter: Self.retryAfterSeconds(httpResponse),
                    dashboardURL: provider.dashboardURL
                )
            }
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SprichError.apiError(httpResponse.statusCode, errorBody)
        }

        // Deepgram response structure
        struct DeepgramResponse: Decodable {
            struct Results: Decodable {
                struct Channel: Decodable {
                    struct Alternative: Decodable {
                        let transcript: String
                    }
                    let alternatives: [Alternative]
                }
                let channels: [Channel]
            }
            let results: Results
        }

        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        guard let transcript = decoded.results.channels.first?.alternatives.first?.transcript else {
            throw SprichError.emptyTranscription
        }

        return transcript
    }
}

// MARK: - Multipart Helper

private extension Data {
    mutating func appendMultipart(boundary: String, name: String, filename: String,
                                   mimeType: String, data: Data) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        append("Content-Type: \(mimeType)\r\n\r\n".data(using: .utf8)!)
        append(data)
        append("\r\n".data(using: .utf8)!)
    }

    mutating func appendMultipart(boundary: String, name: String, value: String) {
        // Strip CR/LF from caller-supplied values to prevent multipart boundary
        // injection via crafted transcripts/glossary terms. The boundary is a
        // random UUID so collision is infeasible, but defense in depth.
        let safe = value.replacingOccurrences(of: "\r", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(safe)\r\n".data(using: .utf8)!)
    }
}
