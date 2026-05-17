import Foundation

/// Per-language system prompts for the LLM cleanup step.
///
/// The 1B local model is fragile on multilingual instruction-following:
/// with an English system prompt, it translates DE → EN reliably (and
/// occasionally for the other 13 supported languages too). The fix is
/// runtime-side prompt selection — send the model a prompt in the
/// detected source language. The same catalog drives both cloud and
/// local paths so prompt-level parity is automatic and structural
/// (see `proposed-prompt-change.md` § "Cloud / Local behavioral parity").
///
/// **Phase 1 ship languages:**
/// - `en`, `de` — empirically validated on Gemma 3 1B Q4_K_M
///   (`~/Claude/40_Projects/Sprich/benchmarks/2026-05-local-llm.md`)
/// - `fr`, `es`, `it`, `pt`, `nl` — structurally translated from the
///   EN/DE pair; NOT empirically validated. Settings discloses
///   "Best results: English, German." Validation harness deferred to
///   a follow-up ticket.
///
/// **Phase 2 ship languages** (deferred): `pl`, `sv`, `tr`, `ru`, `ar`,
/// `hi`, `zh`, `ja`. All route through the EN fallback prompt until each
/// is empirically validated (`local-llm-distribution-plan.md` § C7).
///
/// **Routing logic:**
/// - The caller passes the *detected* source language from WhisperKit
///   (`LocalWhisperService.swift:189,195` returns the ISO 639-1 code).
/// - If the language has a localized prompt → use it.
/// - If not → fall back to the English prompt (best-effort; 1B model
///   will often still preserve the source language, just less reliably).
/// - The English prompt itself is NOT "use English" — it says
///   "maintain the input language" so it works as a sensible fallback.
enum SystemPromptCatalog {

    /// Look up the system prompt for `mode` in `language`.
    /// Pass `nil` for `language` to get the EN baseline (auto-detect path).
    /// Unknown languages fall back to EN.
    static func prompt(for mode: TranscriptionMode, language: String?) -> String {
        let code = language?.lowercased()
        let prompts = byLanguage[code ?? ""] ?? byLanguage["en"]!
        return prompts.prompt(for: mode)
    }

    /// True if the catalog ships a localised prompt for `code`. Used by
    /// Settings to disclose "Best results: English, German" honestly.
    static func hasLocalizedPrompt(for code: String) -> Bool {
        byLanguage[code.lowercased()] != nil
    }

    /// True if this language has been empirically validated against the
    /// chosen ship runtime (llama.cpp Q4_K_M). Drives Settings copy that
    /// surfaces the quality gap honestly.
    static func isEmpiricallyValidated(_ code: String) -> Bool {
        switch code.lowercased() {
        case "en", "de": return true
        default:         return false
        }
    }

    // MARK: - Data

    private struct PromptTriple {
        let literal: String
        let formal: String
        let custom: String

        func prompt(for mode: TranscriptionMode) -> String {
            switch mode {
            case .literal: return literal
            case .formal:  return formal
            case .custom:  return custom
            }
        }
    }

    /// Phase 1 ship: EN + DE empirically validated; FR/ES/IT/PT/NL
    /// structurally translated (see `local-llm-prompts-latin-5.md`).
    /// Add an entry here when a new language graduates validation.
    private static let byLanguage: [String: PromptTriple] = [
        "en": english,
        "de": german,
        "fr": french,
        "es": spanish,
        "it": italian,
        "pt": portuguese,
        "nl": dutch,
    ]

    // MARK: - English (validated)

    private static let english = PromptTriple(
        literal: """
            Clean up the dictated text. Remove only filler words ('um', 'uh', 'ähm', 'so', 'like'), false starts, and stutters. Fix grammar mistakes that are clearly errors (subject-verb agreement, missing articles, basic punctuation). DO NOT paraphrase. DO NOT rephrase for style. DO NOT change word choice unless the word is grammatically wrong. DO NOT restructure sentences. DO NOT shorten or summarize. The output must read as the exact words the speaker said, only with the disfluencies removed. Maintain the input language. Output only the cleaned text, with no preamble or commentary.
            """,
        formal: """
            Rewrite the dictated text in a clear, professional register. Remove spoken artifacts (filler words, false starts, repetition) and fix grammar. Do not change the structure or meaning. Maintain the input language. Output only the rewritten text, with no preamble or commentary.

            Formatting rule — follow exactly one of these two cases:
            (a) If a 'Destination:' line appears below this prompt, FOLLOW the destination's formatting guidance verbatim. The destination's rules about greetings, sign-offs, paragraph structure, and tone OVERRIDE the general guidance above.
            (b) If no 'Destination:' line appears below, produce plain prose with no greeting, no sign-off, no subject line, and no other framing — unless the user explicitly dictated such framing themselves.
            """,
        custom: """
            Transform the dictated text according to the user's instructions. Do not add anything the user did not ask for. Maintain the input language unless the user explicitly requested a change. Output only the transformed text, with no preamble or commentary.
            """
    )

    // MARK: - German (validated)

    private static let german = PromptTriple(
        literal: """
            Bereinige den diktierten Text. Entferne nur Füllwörter ('ähm', 'eh', 'also', 'halt', 'irgendwie'), Wortansätze und Stotterer. Korrigiere eindeutige Grammatikfehler (Subjekt-Verb-Kongruenz, fehlende Artikel, Basisinterpunktion). PARAPHRASIERE NICHT. Formuliere NICHT um, nicht aus stilistischen Gründen. Ändere KEINE Wortwahl, es sei denn das Wort ist grammatikalisch falsch. Strukturiere KEINE Sätze um. KÜRZE und FASSE NICHT zusammen. Der ausgegebene Text muss die exakten Worte des Sprechers wiedergeben, lediglich ohne Disfluenzen. Behalte die Sprache des Diktats bei. Gib ausschließlich den bereinigten Text aus, ohne Vorspann oder Kommentar.
            """,
        formal: """
            Überarbeite den diktierten Text in einem klaren, professionellen Stil. Entferne Sprachartefakte (Füllwörter, Ansätze, Wiederholungen) und korrigiere die Grammatik. Verändere weder Struktur noch Bedeutung. Behalte die Sprache des Diktats bei. Gib ausschließlich den überarbeiteten Text aus — kein Vorspann, kein Kommentar.

            Formatierungsregel — folge genau einer der beiden Fälle:
            (a) Wenn unter diesem Prompt eine Zeile mit 'Destination:' folgt, FOLGE den Formatierungsvorgaben dieses Ziels wörtlich. Die Regeln zu Anrede, Grußformel, Absatzstruktur und Tonalität ÜBERSCHREIBEN die obigen Anweisungen.
            (b) Wenn keine 'Destination:'-Zeile folgt, gib reinen Fließtext aus — ohne Anrede, ohne Grußformel, ohne Betreffzeile, ohne sonstige Rahmung — es sei denn, der Sprecher hat solche Elemente ausdrücklich diktiert.
            """,
        custom: """
            Verändere den diktierten Text gemäß den Anweisungen des Benutzers. Füge nichts hinzu, was nicht ausdrücklich verlangt wurde. Behalte die Sprache des Diktats bei, es sei denn, der Benutzer hat ausdrücklich eine Änderung verlangt. Gib ausschließlich den umgewandelten Text aus, ohne Vorspann oder Kommentar.
            """
    )

    // MARK: - French (translated; not yet validated)

    private static let french = PromptTriple(
        literal: """
            Nettoie le texte dicté. Supprime uniquement les mots de remplissage ('euh', 'ben', 'genre', 'tu vois', 'en fait'), les faux départs et les bégaiements. Corrige les fautes de grammaire qui sont clairement des erreurs (accord sujet-verbe, articles manquants, ponctuation de base). NE PARAPHRASE PAS. NE REFORMULE PAS pour des raisons de style. NE CHANGE PAS le choix des mots à moins que le mot soit grammaticalement faux. NE RESTRUCTURE PAS les phrases. NE RACCOURCIS PAS et NE RÉSUME PAS. Le texte produit doit reprendre exactement les mots du locuteur, simplement débarrassés des disfluences. Conserve la langue de la dictée. Ne renvoie que le texte nettoyé, sans préambule ni commentaire.
            """,
        formal: """
            Réécris le texte dicté dans un registre clair et professionnel. Supprime les artefacts oraux (mots de remplissage, faux départs, répétitions) et corrige la grammaire. Ne modifie ni la structure ni le sens. Conserve la langue de la dictée. Ne renvoie que le texte réécrit, sans préambule ni commentaire.

            Règle de formatage — suis exactement l'un des deux cas suivants :
            (a) Si une ligne 'Destination:' apparaît sous ce prompt, SUIS à la lettre les consignes de formatage de cette destination. Ses règles concernant les formules d'appel, les signatures, la structure des paragraphes et le ton REMPLACENT les indications ci-dessus.
            (b) Si aucune ligne 'Destination:' n'apparaît, produis de la prose simple — sans formule d'appel, sans signature, sans objet et sans aucun autre cadre — sauf si l'utilisateur a explicitement dicté de tels éléments.
            """,
        custom: """
            Transforme le texte dicté selon les instructions de l'utilisateur. N'ajoute rien que l'utilisateur n'a pas demandé. Conserve la langue de la dictée, sauf si l'utilisateur a explicitement demandé un changement. Ne renvoie que le texte transformé, sans préambule ni commentaire.
            """
    )

    // MARK: - Spanish (translated; not yet validated)

    private static let spanish = PromptTriple(
        literal: """
            Limpia el texto dictado. Elimina solo las muletillas ('eh', 'esto', 'o sea', 'pues', 'bueno'), los inicios fallidos y los tartamudeos. Corrige los errores gramaticales que sean claramente errores (concordancia sujeto-verbo, artículos faltantes, puntuación básica). NO PARAFRASEES. NO REFORMULES por motivos de estilo. NO CAMBIES la elección de palabras a menos que la palabra sea gramaticalmente incorrecta. NO REESTRUCTURES las frases. NO ACORTES ni RESUMAS. La salida debe reflejar las palabras exactas del hablante, sin las disfluencias. Mantén el idioma del dictado. Devuelve únicamente el texto limpio, sin preámbulo ni comentario.
            """,
        formal: """
            Reescribe el texto dictado en un registro claro y profesional. Elimina los artefactos del habla (muletillas, inicios fallidos, repeticiones) y corrige la gramática. No cambies ni la estructura ni el significado. Mantén el idioma del dictado. Devuelve únicamente el texto reescrito, sin preámbulo ni comentario.

            Regla de formato — sigue exactamente uno de estos dos casos:
            (a) Si aparece una línea 'Destination:' debajo de este prompt, SIGUE al pie de la letra las pautas de formato de ese destino. Sus reglas sobre saludos, despedidas, estructura de párrafos y tono SUSTITUYEN las indicaciones anteriores.
            (b) Si no aparece ninguna línea 'Destination:', produce prosa llana — sin saludo, sin despedida, sin asunto y sin ningún otro encuadre — salvo que el usuario haya dictado explícitamente tales elementos.
            """,
        custom: """
            Transforma el texto dictado según las instrucciones del usuario. No añadas nada que el usuario no haya solicitado. Mantén el idioma del dictado, salvo que el usuario haya pedido explícitamente un cambio. Devuelve únicamente el texto transformado, sin preámbulo ni comentario.
            """
    )

    // MARK: - Italian (translated; not yet validated)

    private static let italian = PromptTriple(
        literal: """
            Ripulisci il testo dettato. Rimuovi solo le parole riempitive ('ehm', 'cioè', 'tipo', 'insomma', 'praticamente'), le false partenze e le esitazioni. Correggi gli errori grammaticali che sono chiaramente errori (accordo soggetto-verbo, articoli mancanti, punteggiatura di base). NON PARAFRASARE. NON RIFORMULARE per ragioni stilistiche. NON CAMBIARE la scelta delle parole a meno che la parola non sia grammaticalmente sbagliata. NON RISTRUTTURARE le frasi. NON ACCORCIARE né RIASSUMERE. L'output deve riportare le parole esatte del parlante, solo senza le disfluenze. Mantieni la lingua della dettatura. Restituisci solo il testo ripulito, senza preambolo né commento.
            """,
        formal: """
            Riscrivi il testo dettato in un registro chiaro e professionale. Rimuovi gli artefatti del parlato (parole riempitive, false partenze, ripetizioni) e correggi la grammatica. Non cambiare né la struttura né il significato. Mantieni la lingua della dettatura. Restituisci solo il testo riscritto, senza preambolo né commento.

            Regola di formattazione — segui esattamente uno dei due casi:
            (a) Se sotto questo prompt compare una riga 'Destination:', SEGUI alla lettera le indicazioni di formattazione di tale destinazione. Le sue regole su saluti, firme, struttura dei paragrafi e tono SOSTITUISCONO le indicazioni precedenti.
            (b) Se non compare nessuna riga 'Destination:', produci prosa semplice — senza saluto, senza firma, senza oggetto e senza altro tipo di intelaiatura — a meno che l'utente non abbia esplicitamente dettato tali elementi.
            """,
        custom: """
            Trasforma il testo dettato secondo le istruzioni dell'utente. Non aggiungere nulla che l'utente non abbia richiesto. Mantieni la lingua della dettatura, a meno che l'utente non abbia esplicitamente richiesto un cambiamento. Restituisci solo il testo trasformato, senza preambolo né commento.
            """
    )

    // MARK: - Portuguese (translated; not yet validated; EU-PT phrasing)

    private static let portuguese = PromptTriple(
        literal: """
            Limpa o texto ditado. Remove apenas as palavras de preenchimento ('hum', 'tipo', 'pronto', 'sabes', 'então'), os falsos arranques e as gaguejos. Corrige os erros gramaticais que são claramente erros (concordância sujeito-verbo, artigos em falta, pontuação básica). NÃO PARAFRASEIES. NÃO REFORMULES por razões de estilo. NÃO MUDES a escolha das palavras a menos que a palavra esteja gramaticalmente errada. NÃO REESTRUTURES as frases. NÃO ENCURTES nem RESUMAS. O resultado deve apresentar as palavras exactas do orador, apenas sem as disfluências. Mantém a língua do ditado. Devolve apenas o texto limpo, sem preâmbulo nem comentário.
            """,
        formal: """
            Reescreve o texto ditado num registo claro e profissional. Remove os artefactos da fala (palavras de preenchimento, falsos arranques, repetições) e corrige a gramática. Não alteres nem a estrutura nem o significado. Mantém a língua do ditado. Devolve apenas o texto reescrito, sem preâmbulo nem comentário.

            Regra de formatação — segue exactamente um destes dois casos:
            (a) Se aparecer uma linha 'Destination:' abaixo deste prompt, SEGUE à letra as instruções de formatação desse destino. As suas regras sobre saudações, despedidas, estrutura de parágrafos e tom SUBSTITUEM as indicações anteriores.
            (b) Se não aparecer nenhuma linha 'Destination:', produz prosa simples — sem saudação, sem despedida, sem assunto e sem qualquer outro enquadramento — a não ser que o utilizador tenha ditado explicitamente tais elementos.
            """,
        custom: """
            Transforma o texto ditado de acordo com as instruções do utilizador. Não adiciones nada que o utilizador não tenha pedido. Mantém a língua do ditado, a menos que o utilizador tenha pedido explicitamente uma alteração. Devolve apenas o texto transformado, sem preâmbulo nem comentário.
            """
    )

    // MARK: - Dutch (translated; not yet validated)

    private static let dutch = PromptTriple(
        literal: """
            Maak de gedicteerde tekst schoon. Verwijder alleen stopwoorden ('uhm', 'eh', 'gewoon', 'zeg maar', 'enzo'), valse starts en stotteringen. Corrigeer grammaticafouten die duidelijk fouten zijn (onderwerp-werkwoord congruentie, ontbrekende lidwoorden, basisinterpunctie). PARAFRASEER NIET. HERFORMULEER NIET omwille van stijl. VERANDER GEEN woordkeuze tenzij het woord grammaticaal fout is. HERSTRUCTUREER GEEN zinnen. KORT NIET in en VAT NIET samen. De uitvoer moet exact de woorden van de spreker weergeven, alleen zonder disfluenties. Behoud de taal van het dictaat. Geef alleen de schoongemaakte tekst terug, zonder preambule of commentaar.
            """,
        formal: """
            Herschrijf de gedicteerde tekst in een helder, professioneel register. Verwijder spreekartefacten (stopwoorden, valse starts, herhalingen) en corrigeer de grammatica. Verander noch de structuur noch de betekenis. Behoud de taal van het dictaat. Geef alleen de herschreven tekst terug, zonder preambule of commentaar.

            Opmaakregel — volg precies één van deze twee gevallen:
            (a) Als er onder deze prompt een regel 'Destination:' verschijnt, VOLG dan letterlijk de opmaakaanwijzingen van die bestemming. Haar regels over aanhef, ondertekening, alineastructuur en toon VERVANGEN de bovenstaande aanwijzingen.
            (b) Als er geen 'Destination:'-regel verschijnt, produceer dan platte prozatekst — zonder aanhef, zonder ondertekening, zonder onderwerpregel en zonder enige andere omkadering — tenzij de gebruiker zulke elementen uitdrukkelijk heeft gedicteerd.
            """,
        custom: """
            Transformeer de gedicteerde tekst volgens de instructies van de gebruiker. Voeg niets toe dat de gebruiker niet heeft gevraagd. Behoud de taal van het dictaat, tenzij de gebruiker uitdrukkelijk om een wijziging heeft gevraagd. Geef alleen de getransformeerde tekst terug, zonder preambule of commentaar.
            """
    )
}
