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

    /// Build the final system prompt for an LLM mode:
    ///   immutable core  (+ optional user style layer)  (+ surface hint)
    ///
    /// `core` is the per-language immutable safety prompt from
    /// `SystemPromptCatalog` — the "you are a rewriter, not an assistant"
    /// framing plus the anti-injection rules. It ALWAYS leads, so the user's
    /// editable layer (or an injected instruction) can never strip it.
    /// `editableLayer` is the user's optional Formal/Custom style addition
    /// (empty by default). The surface hint (`Destination: …`) is appended
    /// for Formal only, when `adaptToSurface` is on. Pure/static so it can
    /// be unit tested without touching any provider or settings side effects.
    static func composeSystemPrompt(
        core: String,
        mode: TranscriptionMode,
        editableLayer: String,
        surface: Surface,
        adaptToSurface: Bool
    ) -> String {
        // Literal never reaches the LLM; return the core for completeness.
        guard mode == .formal || mode == .custom else { return core }
        var prompt = core
        let layer = editableLayer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !layer.isEmpty { prompt += "\n\n" + layer }
        if mode == .formal, adaptToSurface {
            let hint = surface.promptHint
            if !hint.isEmpty { prompt += "\n\n" + hint }
        }
        return prompt
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
    ///
    /// For Formal mode, `inputText` is Pass-1 (literal-cleaned) text —
    /// `PipelineCoordinator` runs `polishLiteral` before calling here. The
    /// LLM's output is gated by `FormalOutputGuard` against a sentence-
    /// count contract; on breach we silently return `inputText` (the
    /// Pass-1 baseline). Custom mode skips the guard — user-driven prompts
    /// aren't held to the Formal contract. Literal mode never reaches
    /// here (PipelineCoordinator pastes Pass-1 directly).
    ///
    /// `surface` is the resolved destination (email / slack / docs / …)
    /// and is only applied when `mode == .formal` and
    /// `settings.adaptToSurface == true`.
    func cleanup(
        inputText: String,
        mode: TranscriptionMode,
        settings: AppSettings,
        surface: Surface = .generic
    ) async throws -> String {
        let sanitizedText = InputSanitizer.sanitize(inputText)

        guard !sanitizedText.isEmpty else {
            throw SprichError.emptyTranscription
        }

        // Short-input bypass (mirrors LocalLLMService). A tiny Formal
        // dictation — "Thanks.", or an accidental 2-second hotkey press that
        // yields ~10 chars — makes the model hallucinate the in-prompt
        // instructions/examples back as output (observed: an 11-char input
        // producing a 392-char regurgitation of the task-ticket guidelines).
        // Pass-1 already handled capitalization + punctuation at this length,
        // so skip the LLM and return it. Cloud path only; `.local` delegates
        // to LocalLLMService which applies the same bypass.
        if mode == .formal, settings.llmProvider != .local,
           sanitizedText.count < LocalLLMService.shortInputBypassChars {
            #if DEBUG
            print("[Sprich] Formal short-input bypass (cloud): \(sanitizedText.count) chars < \(LocalLLMService.shortInputBypassChars)")
            #endif
            return sanitizedText
        }

        // Immutable per-language core (anti-injection spine) from the same
        // catalog the local path uses — cloud + local now share it, so the
        // safety guarantee is structural across providers.
        let core = SystemPromptCatalog.prompt(for: mode, language: settings.preferredLanguage)
        let systemPrompt = Self.composeSystemPrompt(
            core: core,
            mode: mode,
            editableLayer: settings.editableLayer(for: mode),
            surface: surface,
            adaptToSurface: settings.adaptToSurface
        )

        // Per-dictation output budget. The Formal Pass-2 contract is "polish,
        // same sentence count ±1" — the model has no business writing a
        // 1024-token essay from a 50-char input. Cap proportionally to input
        // length, with headroom for register lift and a hard floor for very
        // short dictations ("Thanks." → 82 tokens still leaves room).
        let maxTokens = Self.budgetTokens(for: sanitizedText)

        // Route to the configured provider. Local delegates to
        // LocalLLMService which runs its own guard internally; cloud paths
        // return the raw LLM string here and we wrap once at the bottom.
        let rawLLMOutput: String
        switch settings.llmProvider {
        case .groq:
            rawLLMOutput = try await callGroqLLM(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.groqLLMModel,
                maxTokens: maxTokens
            )
        case .claude:
            rawLLMOutput = try await callClaude(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.claudeModel,
                maxTokens: maxTokens
            )
        case .google:
            rawLLMOutput = try await callGemini(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.googleModel,
                maxTokens: maxTokens
            )
        case .openai:
            rawLLMOutput = try await callOpenAI(
                systemPrompt: systemPrompt,
                userMessage: sanitizedText,
                model: settings.openAILLMModel,
                maxTokens: maxTokens
            )
        case .local:
            // On-device cleanup via llama.cpp + Gemma 3 1B-it Q4_K_M.
            // Decision 5a/5b/5c: there is NO cloud fallback in this branch
            // — if `LocalLLMService` fails, the error surfaces to the user
            // and Settings is the only path back to a cloud provider.
            //
            // LocalLLMService applies FormalOutputGuard internally, so we
            // return its result directly without re-wrapping.
            return try await LocalLLMService.shared.cleanup(
                inputText: inputText,
                mode: mode,
                settings: settings,
                surface: surface
            )
        }

        // Cloud post-processing. Formal mode enforces the sentence-count
        // contract; non-Formal modes (Custom) only get artifact cleanup.
        if mode == .formal {
            let effectiveSurface: Surface = settings.adaptToSurface ? surface : .generic
            let result = FormalOutputGuard.enforce(
                pass1Text: sanitizedText,
                rawLLMOutput: rawLLMOutput,
                language: settings.preferredLanguage,
                surface: effectiveSurface
            )
            #if DEBUG
            if result.usedFallback {
                print("[Sprich] Formal guard fallback (cloud): \(result.fallbackReason ?? "?")")
            }
            #endif
            // Deterministic shape normalisation — ensures email greeting/
            // sign-off get blank-line framing even when the model produced
            // only half the shape. No-op on non-email surfaces.
            return TextPostProcessor.normalizeShape(result.text, surface: effectiveSurface)
        } else {
            // Custom mode (H1): immutable core + minimal runaway-generation
            // backstop. Not held to the Formal contract.
            let result = FormalOutputGuard.enforceCustom(
                inputText: sanitizedText,
                rawLLMOutput: rawLLMOutput
            )
            #if DEBUG
            if result.usedFallback {
                print("[Sprich] Custom guard fallback (cloud): \(result.fallbackReason ?? "?")")
            }
            #endif
            return result.text
        }
    }

    /// Per-call output cap: `min(1024, (input_chars / 3) + 80)`. Floor of
    /// ~82 tokens covers single-sentence dictations; cap at 1024 keeps
    /// long multi-paragraph dictations workable. Stops the model from
    /// emitting a runaway list when the dictation is one question.
    static func budgetTokens(for inputText: String) -> Int {
        let estimate = (inputText.count / 3) + 80
        return min(1024, max(estimate, 80))
    }

    // MARK: - Groq LLM (fastest — reuses STT API key)

    private func callGroqLLM(
        systemPrompt: String,
        userMessage: String,
        model: String,
        maxTokens: Int
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
            "max_tokens": maxTokens,
            // 0.0 — see comment in `LocalLLMService.swift` re: greedy decoding.
            // Sprich polishes text; sampling produced inconsistent outputs
            // (same input → different output) which is wrong for this product.
            "temperature": 0.0,
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
        model: String,
        maxTokens: Int
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
            "max_tokens": maxTokens,
            // 0.0 — same rationale as Groq above. Anthropic default is 1.0;
            // an unset temperature gave wildly varying polish outputs.
            "temperature": 0.0,
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
        model: String,
        maxTokens: Int
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
                "maxOutputTokens": maxTokens,
                // 0.0 — same rationale as Groq/Claude above.
                "temperature": 0.0,
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
        model: String,
        maxTokens: Int
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
            "max_tokens": maxTokens,
            // 0.0 — OpenAI default is 1.0; same rationale as the other
            // providers above (deterministic polishing, not creative writing).
            "temperature": 0.0,
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
