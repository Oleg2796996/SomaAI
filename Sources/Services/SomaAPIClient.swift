import Foundation

// MARK: - Response Models
struct SomaBrainResponse: Codable {
    let markers: [SomaMarker]
}

struct SomaMarker: Codable, Identifiable {
    var id: String { name + (unit ?? "") }
    var name: String
    var value: String
    var unit: String?
    var referenceRange: String?
    var flag: String? // High, Low, Normal
}

// MARK: - Universal Document Pipeline (3-step)

/// Step-1 response: minimal JSON with one enum value.
struct SomaClassifyResponse: Codable {
    let type: String         // DocumentType.rawValue, e.g. "labResult"
    let confidence: Double   // 0.0–1.0
    let organization: String?
}

/// Step-2 response: per-type polymorphic payload. The actual schema
/// depends on the classified `documentType` — see `SomaPrompts`.
struct SomaExtractionResponse: Codable {
    let type: String
    let date: String?        // ISO yyyy-MM-dd
    let organization: String?
    let title: String?
    let confidence: Double

    // Lab-specific
    let markers: [SomaMarker]?

    // Prescription-specific
    let medications: [SomaMedication]?

    // Epicrisis / consultation / discharge / imaging / unknown — key/value
    let sections: [SomaSection]?
}

struct SomaMedication: Codable, Identifiable {
    var id: String { name + (dose ?? "") }
    var name: String
    var dose: String?
    var frequency: String?
    var duration: String?
    var route: String?
}

struct SomaSection: Codable, Identifiable {
    var id: String { key }
    var key: String
    var value: String
    var order: Int?
}

// MARK: - API Configuration
struct SomaAPISettings: Codable {
    var baseURL: String
    var modelName: String

    /// Wormsoft model alias. Wormsoft rotates through a list of upstream
    /// models per alias — the first one that answers gets used.
    ///   agent/low     → qwen3-vl → qwen3.5:235b → qwen3.6:35b → deepseek-v3.1
    ///                  Fastest, qwen3-vl usually responds in 3-5s.
    ///   agent/medium  → gemma4:31b → qwen3.6:27b → qwen3.6:35b → minimax-m2.7
    ///                  Same chain as code/medium but routed via the 'agent'
    ///                  pool which is less loaded than 'code' at peak hours.
    ///   code/medium   → gemma4:31b → qwen3.6:27b → minimax-m2.7
    ///                  Was the original default — gemma4 was timing out at
    ///                  25-35s during the user's 2026-06-26 testing.
    /// We pick agent/low here so the user gets a fast qwen3-vl response
    /// for short clinical extraction. If quality drops, change to
    /// 'wormsoft/agent/medium' or 'wormsoft/agent/high'.
    ///
    /// UPDATED 2026-06-26: the user's curl test showed that 'agent/low'
    /// is reachable (auth OK), but their subscription only has steady
    /// access to 'code/medium' — 'agent/low' rate-limited or in
    /// maintenance for their API key. Reverting to 'code/medium' so the
    /// app gets consistent ~3-8s responses again.
    static let defaultSettings = SomaAPISettings(
        baseURL: "https://ai.wormsoft.ru/api/gpt",
        modelName: "wormsoft/code/medium"
    )

    static func load() -> SomaAPISettings {
        let base = UserDefaults.standard.string(forKey: "soma_api_base_url")
        let model = UserDefaults.standard.string(forKey: "soma_api_model_name")
        return SomaAPISettings(
            baseURL: (base?.isEmpty == false) ? base! : defaultSettings.baseURL,
            modelName: (model?.isEmpty == false) ? model! : defaultSettings.modelName
        )
    }

    func save() {
        UserDefaults.standard.set(baseURL, forKey: "soma_api_base_url")
        UserDefaults.standard.set(modelName, forKey: "soma_api_model_name")
    }
}
/// Sprint 4.7e: provider routing. Each provider has its own API key
/// stored in iOS Keychain (separate accounts). Enables multi-provider
/// fallback chain in `SomaAPIClient.extractDocument`.
enum APIProvider: String, CaseIterable, Identifiable, Codable {
    case wormsoft       // ai.wormsoft.ru (current default)
    case openai         // api.openai.com (Sprint 4.7e — fallback)
    
    var id: String { rawValue }
    
    /// Keychain account name. Multiple providers co-exist safely.
    var keychainAccount: String {
        switch self {
        case .wormsoft: return "soma_api_key_wormsoft"
        case .openai:   return "soma_api_key_openai"
        }
    }
    
    /// OpenAI-compatible baseURL. Both providers use /v1/chat/completions.
    var baseURL: String {
        switch self {
        case .wormsoft: return "https://ai.wormsoft.ru/api/gpt"
        case .openai:   return "https://api.openai.com/v1"
        }
    }
    
    /// Display name for Settings UI.
    var displayName: String {
        switch self {
        case .wormsoft: return "Wormsoft"
        case .openai:   return "OpenAI"
        }
    }
    
    /// Default model for that provider.
    var defaultModel: String {
        switch self {
        case .wormsoft: return "wormsoft/code/medium"
        case .openai:   return "gpt-4o-mini"
        }
    }
    
    /// Model chain to try in order (Sprint 4.7 multi-model fallback).
    var modelChain: [String] {
        switch self {
        case .wormsoft:
            // Code-specialized chain (best for JSON extraction).
            return [
                "wormsoft/code/high",
                "wormsoft/code/medium",
                "wormsoft/agent/low"
            ]
        case .openai:
            // OpenAI: 4o-mini is fast + cheap, then 4o if needed.
            return [
                "gpt-4o-mini",
                "gpt-4o"
            ]
        }
    }
}

// MARK: - Client
final class SomaAPIClient {
    static let shared = SomaAPIClient()

    private func apiKey(for provider: APIProvider) -> String {
        do {
            return try KeychainHelper.shared.read(accountName: provider.keychainAccount)
        } catch {
            return ""
        }
    }
    // Sprint 4.7e: backward-compat alias for pre-4.7e callers (returns wormsoft key).
    private var apiKey: String { apiKey(for: .wormsoft) }

    private var settings: SomaAPISettings { SomaAPISettings.load() }

    private var chatEndpoint: String {
        var url = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/v1") {
            return url + "/chat/completions"
        } else if url.hasSuffix("/v1/chat") {
            return url + "/completions"
        } else {
            return url + "/v1/chat/completions"
        }
    }

    /// Sends raw OCR text to the configured LLM and asks for a JSON array of lab markers.
    /// Kept for backward compat — internally now routes through the
    /// 3-step pipeline when the caller asks for universal extraction.
    func structureText(_ text: String) async throws -> [SomaMarker] {
        let result = try await processDocument(text)
        return result.markers ?? []
    }

    // MARK: 3-step pipeline entry point

    /// Universal 3-step document processor. Replaces the old single-shot
    /// `structureText`. Caller gets back a flat, normalised payload that
    /// the UI can directly map to `MedicalDocument`.
    func processDocument(_ text: String) async throws -> SomaExtractionResponse {
        // Overall 50s guard around the whole pipeline. If the LLM
        // endpoint hangs on any of the 4 calls (classify×3 + extract
        // + validate), we return unknown with raw sections instead of
        // leaving the user staring at a frozen spinner. The verification
        // UI knows how to render .unknown + raw text.
        //
        // Race-condition fix: we use TWO task groups instead of one.
        //  - Inner pipeline task runs to completion (up to ~50s with
        //    all the per-call timeouts).
        //  - Outer sleep task races against it but DOES NOT return its
        //    result — it just signals the timer fired.
        // If the inner pipeline finishes first (normal case), we cancel
        // the sleep task. If the sleep task finishes first, we cancel
        // the pipeline. In both cases we return the PIPELINE result, not
        // the timer result — this prevents the bug where the timer
        // raced past the LocalExtractor fallback and overrode 9 valid
        // sections with an empty 'unknown' result.
        return await withTaskGroup(of: SomaExtractionResponse?.self) { outerGroup in
            outerGroup.addTask {
                do {
                    let cleaned = self.preprocessForClassification(text)
                    let body = cleaned.count > 200 ? cleaned : text
                    let classification = try await self.smartClassify(body)
                    let docType = DocumentType(rawValue: classification.type) ?? .unknown
                    let extraction = try await self.extractDocument(body, type: docType)
                    return self.validate(extraction: extraction, classification: classification, expectedType: docType)
                } catch {
                    print("[SomaAI] processDocument inner catch: \(error.localizedDescription) — trying LocalExtractor")
                    // Try local regex before falling back to raw text.
                    let local = LocalExtractor.extract(text, type: .unknown)
                    if local.sections?.isEmpty == false || local.markers?.isEmpty == false || local.medications?.isEmpty == false {
                        print("[SomaAI] processDocument LocalExtractor sections=\(local.sections?.count ?? 0) conf=\(local.confidence)")
                        return local
                    }
                    return SomaExtractionResponse(
                        type: DocumentType.unknown.rawValue,
                        date: nil, organization: nil, title: nil,
                        confidence: 0.0,
                        markers: nil, medications: nil,
                        sections: [SomaSection(key: "Текст", value: text, order: 0)]
                    )
                }
            }
            outerGroup.addTask {
                try? await Task.sleep(nanoseconds: 75_000_000_000)
                print("[SomaAI] processDocument overall 75s reached — cancelling pipeline")
                return nil  // signal timer fired, but DO NOT return a result
            }
            // Wait for the first non-nil result (the pipeline finished).
            var final: SomaExtractionResponse?
            // The pipeline task and the timer task both write to outerGroup.
            // We want the pipeline result. Iterate until we get one.
            // DO NOT break on nil (timer fired) — the pipeline may still
            // be running and about to deliver a real result. The timer
            // task just signals that we SHOULD have seen the pipeline by
            // now; it doesn't replace the pipeline's output.
            for await r in outerGroup {
                if let r = r {
                    final = r
                    break
                }
                // r == nil — timer fired. Print a warning but keep waiting
                // for the pipeline. The pipeline has its own 25s LLM
                // timeout + LocalExtractor fallback, so it should finish
                // within ~30s after the timer.
                print("[SomaAI] processDocument 50s timer fired — waiting for pipeline to deliver (LocalExtractor or raw text fallback)")
            }
            // Drain: read any leftover result the pipeline may have just
            // produced (it can finish a few ms after the timer).
            for await r in outerGroup {
                if let r = r, final == nil { final = r }
            }
            return final ?? SomaExtractionResponse(
                type: DocumentType.unknown.rawValue,
                date: nil, organization: nil, title: nil,
                confidence: 0.0,
                markers: nil, medications: nil,
                sections: [SomaSection(key: "Текст", value: text, order: 0)]
            )
        }
    }

    // MARK: Classification pre-processing + multi-vote

    /// Clean OCR garbage that misleads the LLM classifier. The biggest
    /// offenders in Russian medical scans are:
    ///   - isolated digits / page numbers ("934)", "714", "11:161")
    ///   - duplicated header lines (the scanner stamps the same
    ///     "КОНОВАЛОВ О. А. ИБ Nº 26714" 2–3 times per page)
    ///   - short all-digit lines, e.g. "<\n934"
    func preprocessForClassification(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        var seen: [String: Int] = [:]
        var out: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // Drop lines that are pure digits / pure digit+digit+digit+punct.
            let digitCount = line.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }.count
            if digitCount >= max(3, line.count - 2) && line.count < 16 { continue }
            // Drop very short all-symbolic lines like "<", "•••".
            if line.count <= 3 && line.unicodeScalars.allSatisfy({ !CharacterSet.letters.contains($0) }) { continue }
            // Dedup near-identical lines (allow 2 copies, drop the 3rd+).
            let key = String(line.prefix(40)).lowercased()
            seen[key, default: 0] += 1
            if (seen[key] ?? 0) > 2 { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }

    /// Three sample windows of the (preprocessed) text. The LLM sees
    /// only the relevant slice. We pick the slice whose majority vote
    /// is strongest — this prevents the "first 200 chars are изосерология,
    /// the rest is эпикриз" trap that confuses a single-pass classifier.
    func smartClassify(_ text: String) async throws -> SomaClassifyResponse {
        // STEP 0: regex precheck. If the document has a clear header keyword,
        // we don't need the LLM at all. This catches 90% of cases in <1ms.
        if let regexHit = regexClassify(text) {
            print("[SomaAI] smartClassify: regex precheck hit → \(regexHit.type)@\(regexHit.confidence) (org=\(regexHit.organization ?? "nil"))")
            return regexHit
        }

        // STEP 1: preprocess to drop OCR garbage before LLM sees it.
        let cleaned = preprocessForClassification(text)
        let body = cleaned.count > 200 ? cleaned : text
        // Cap to first 3000 chars — most Russian medical docs fit in this
        // window for the *head* of the document (the title/type usually
        // appears in the first 1-2 pages).
        let trimmed = body.count > 3000 ? String(body.prefix(3000)) : body

        // STEP 2: single LLM call with 8s timeout. The 3-vote multi-vote
        // added 15-20s latency and frequently hit the 30s overall guard.
        // 1 call is faster and the regex precheck already covers the
        // hard cases. The classifier will fall back to .unknown if the
        // call times out.
        let result = await sendChatWithTimeout(messages: [
            ["role": "system", "content": SomaPrompts.documentClassifier],
            ["role": "user", "content": trimmed]
        ], temperature: 0.0, seconds: 8)

        if let vote = result.vote {
            print("[SomaAI] smartClassify: LLM vote → \(vote.type)@\(vote.confidence)")
            // Sprint 4.9 fallback: if LLM said unknown@0.0 (or very low)
            // but text screams "lab", trust the text.
            if vote.type == DocumentType.unknown.rawValue && vote.confidence <= 0.1 {
                if let labHint = self.regexClassify(text), labHint.type == DocumentType.labResult.rawValue {
                    print("[SomaAI] smartClassify: LLM said unknown but labHint → promoting to labResult@\(labHint.confidence * 0.8)")
                    return SomaClassifyResponse(
                        type: DocumentType.labResult.rawValue,
                        confidence: labHint.confidence * 0.8,  // discount slightly
                        organization: labHint.organization
                    )
                }
            }
            return vote
        }
        print("[SomaAI] smartClassify: LLM timed out/failed → returning unknown@0.4 (user can re-type)")
        return SomaClassifyResponse(type: DocumentType.unknown.rawValue, confidence: 0.4, organization: nil)
    }

    /// Fast deterministic classifier using regex on the cleaned text.
    /// Returns nil if no clear header keyword is found (caller falls back
    /// to a single LLM call). Russian + English headers supported.
    func regexClassify(_ text: String) -> SomaClassifyResponse? {
        let lower = text.lowercased()
        // (pattern, type, confidence) — first match wins.
        let rules: [(String, String, Double)] = [
            // Discharge summary / выписной эпикриз — check BEFORE plain
            // 'эпикриз' because the word 'выписной' is the disambiguator.
            ("эпикриз выписной",      DocumentType.dischargeSummary.rawValue, 0.90),
            ("выписка из",            DocumentType.dischargeSummary.rawValue, 0.85),
            ("выписной эпикриз",      DocumentType.dischargeSummary.rawValue, 0.90),
            ("discharge summary",     DocumentType.dischargeSummary.rawValue, 0.90),
            ("discharge summary:",    DocumentType.dischargeSummary.rawValue, 0.90),
            // Plain epicrisis (not выписной)
            ("эпикриз",               DocumentType.epicrisis.rawValue, 0.80),
            ("epicrisis",             DocumentType.epicrisis.rawValue, 0.80),
            // Consultation / specialist note
            ("консультация",          DocumentType.consultation.rawValue, 0.75),
            ("заключение специалиста",DocumentType.consultation.rawValue, 0.80),
            ("осмотр врача",          DocumentType.consultation.rawValue, 0.70),
            ("consultation",          DocumentType.consultation.rawValue, 0.75),
            // Referral
            ("направление к",         DocumentType.referral.rawValue, 0.85),
            ("направить к",           DocumentType.referral.rawValue, 0.80),
            ("прошу обследовать",     DocumentType.referral.rawValue, 0.80),
            ("referral",              DocumentType.referral.rawValue, 0.75),
            // Vaccination
            ("прививка",              DocumentType.vaccination.rawValue, 0.85),
            ("вакцинация",            DocumentType.vaccination.rawValue, 0.85),
            ("vaccination",           DocumentType.vaccination.rawValue, 0.85),
            // Imaging
            ("рентгенограмма",        DocumentType.imagingReport.rawValue, 0.80),
            ("протокол кт",           DocumentType.imagingReport.rawValue, 0.85),
            ("протокол мрт",          DocumentType.imagingReport.rawValue, 0.85),
            ("протокол узи",          DocumentType.imagingReport.rawValue, 0.85),
            ("заключение экг",        DocumentType.imagingReport.rawValue, 0.85),
            ("заключение эхокг",      DocumentType.imagingReport.rawValue, 0.85),
            ("radiology report",      DocumentType.imagingReport.rawValue, 0.80),
            // Prescription
            ("рецепт на",             DocumentType.prescription.rawValue, 0.80),
            ("назначение:",           DocumentType.prescription.rawValue, 0.60),  // weak — also in epicrisis
            ("\\brp\\.\\s",           DocumentType.prescription.rawValue, 0.85),  // Rp. with period
            ("prescription",          DocumentType.prescription.rawValue, 0.75),
            // Lab result — lower priority because embedded Изосерология
            // can show up inside an epicrisis. Only match strong lab headers.
            ("общий анализ крови",    DocumentType.labResult.rawValue, 0.90),
            ("общий анализ мочи",     DocumentType.labResult.rawValue, 0.90),
            ("биохимический анализ",  DocumentType.labResult.rawValue, 0.90),
            ("complete blood count",  DocumentType.labResult.rawValue, 0.90),
            ("urinalysis",            DocumentType.labResult.rawValue, 0.90),
            // Sprint 4.9: explicit lab headers from НКЦ2 РНЦХ формат.
            // These are the strong signals that indicate a standalone lab
            // document (not embedded labs in an epicrisis).
            ("клинико-диагностическая лаборатория", DocumentType.labResult.rawValue, 0.95),
            ("клинический анализ крови",            DocumentType.labResult.rawValue, 0.92),
            ("биохимическое исследование",           DocumentType.labResult.rawValue, 0.90),
            ("коагулограмма",                       DocumentType.labResult.rawValue, 0.92),
            ("липидограмма",                        DocumentType.labResult.rawValue, 0.92),
            ("гормональное исследование",            DocumentType.labResult.rawValue, 0.90),
            ("изосерология",                        DocumentType.labResult.rawValue, 0.92),
            ("иммунологическое исследование",        DocumentType.labResult.rawValue, 0.90),
            ("пцр-исследование",                    DocumentType.labResult.rawValue, 0.90),
            ("бактериологическое исследование",     DocumentType.labResult.rawValue, 0.90),
            ("цитологическое исследование",         DocumentType.labResult.rawValue, 0.90),
            ("гистологическое исследование",        DocumentType.labResult.rawValue, 0.90),
            ("cbc",                                 DocumentType.labResult.rawValue, 0.85),
            ("lipid panel",                         DocumentType.labResult.rawValue, 0.85),
        ]
        for (pattern, type, conf) in rules {
            if lower.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                return SomaClassifyResponse(type: type, confidence: conf, organization: nil)
            }
        }
        return nil
    }

    // MARK: Step 1 — classify

    /// LLM step 1: returns a single DocumentType enum value.
    /// Falls back to `.unknown` if LLM misbehaves; never throws.
    func classifyDocument(_ text: String) async throws -> SomaClassifyResponse {
        let messages: [[String: String]] = [
            ["role": "system", "content": SomaPrompts.documentClassifier],
            ["role": "user", "content": text]
        ]
        let content = try await sendChat(messages: messages, temperature: 0.0)
        let preview = String(content.prefix(400))
        print("[SomaAI] classify raw response (\(content.count) chars): \(preview)")
        guard let data = content.data(using: .utf8) else {
            return SomaClassifyResponse(type: DocumentType.unknown.rawValue, confidence: 0.0, organization: nil)
        }
        do {
            return try JSONDecoder().decode(SomaClassifyResponse.self, from: data)
        } catch {
            print("[SomaAI] classify decode failed: \(error.localizedDescription)")
            print("[SomaAI] full content was: \(content)")
            return SomaClassifyResponse(type: DocumentType.unknown.rawValue, confidence: 0.0, organization: nil)
        }
    }

    // MARK: Step 2 — extract

    /// LLM step 2: type-aware extraction. Each DocumentType has its own
    /// prompt + JSON schema (see SomaPrompts). Unknown documents fall
    /// back to a generic key/value extractor.
    func extractDocument(_ text: String, type: DocumentType) async throws -> SomaExtractionResponse {
        let prompt: String
        switch type {
        case .labResult: prompt = SomaPrompts.labMarkerExtractor
        case .prescription: prompt = SomaPrompts.prescriptionExtractor
        case .epicrisis, .dischargeSummary, .consultation:
            prompt = SomaPrompts.epicrisisExtractor(forType: type)
        case .referral: prompt = SomaPrompts.referralExtractor
        case .imagingReport: prompt = SomaPrompts.imagingExtractor
        case .vaccination: prompt = SomaPrompts.vaccinationExtractor
        case .unknown: prompt = SomaPrompts.genericExtractor
        }
        let messages: [[String: String]] = [
            ["role": "system", "content": prompt],
            ["role": "user", "content": text]
        ]

        // Sprint 4.7e/4.7m: provider chain.
        // First try Wormsoft (3 models: code/high → code/medium → agent/low);
        // if all fail AND OpenAI key is set, try OpenAI (2 models).
        // If everything fails, LocalExtractor.
        //
        // Order matters: Wormsoft is primary because code/high (minimax-m3)
        // produces clean JSON and was verified 2026-07-09 to be the best
        // extraction model we have access to. OpenAI stays as diversity fallback.
        // Sprint 4.7i diagnostic: log FULL OCR text sent to LLM (truncated to 3000 chars to avoid log spam).
        print("[SomaAI] extract FULL TEXT (\(text.count) chars) → LLM: \(String(text.prefix(3000)))")
        // Sprint 4.7p: 15s was too aggressive — iOS URLSession + Apple ATS
        // overhead on first request can hit 18-20s, so 15s always cancelled
        // before the model had a chance to respond. Bumped to 35s to give
        // room for TLS handshake, certificate verification, and reasoning
        // models (minimax-m3) to actually finish.
        let perProviderTimeoutNs: UInt64 = 35_000_000_000  // 35s per model
        let providerChain: [APIProvider] = [.wormsoft, .openai]
        var triedProviders: [String] = []
        var currentResponse: String?
        // Sprint 4.7e: outer loop over providers, inner over each provider's model chain.
        // Skips providers with empty API key.
        outer: for provider in providerChain {
            let key = apiKey(for: provider)
            if key.isEmpty {
                print("[SomaAI] extract type=\(type.rawValue) provider \(provider.displayName) skipped — no API key")
                continue
            }
            for model in provider.modelChain {
                triedProviders.append("\(provider.displayName)/\(model)")
                do {
                    let result = try await withThrowingTaskGroup(of: String.self) { group in
                        group.addTask {
                            try await self.sendChat(
                                messages: messages, temperature: 0.0, model: model,
                                provider: provider, apiKey: key,
                                endpoint: provider.baseURL + "/chat/completions"
                            )
                        }
                        group.addTask {
                            try await Task.sleep(nanoseconds: perProviderTimeoutNs)
                            throw CancellationError()
                        }
                        let first = try await group.next()!
                        group.cancelAll()
                        return first
                    }
                    currentResponse = result
                    if triedProviders.count > 1 {
                        print("[SomaAI] extract type=\(type.rawValue) recovered with \(provider.displayName)/\(model) after \(triedProviders.count - 1) failures")
                    }
                    break outer  // success
                } catch {
                    print("[SomaAI] extract type=\(type.rawValue) model \(provider.displayName)/\(model) failed: \(error.localizedDescription) — trying next")
                    continue
                }
            }
        }
        guard let finalContent = currentResponse else {
            print("[SomaAI] extract type=\(type.rawValue) all \(triedProviders.count) models across providers failed — falling back to LocalExtractor")
            let local = LocalExtractor.extract(text, type: type)
            print("[SomaAI] localExtract type=\(type.rawValue) → markers=\(local.markers?.count ?? 0), meds=\(local.medications?.count ?? 0), sections=\(local.sections?.count ?? 0), conf=\(local.confidence)")
            return local
        }
        let contentForDecode = Self.stripMarkdownFences(finalContent)
        let content = contentForDecode  // alias for downstream code
        let preview = String(content.prefix(800))
        print("[SomaAI] extract type=\(type.rawValue) raw response (\(content.count) chars): \(preview)")
        guard let data = content.data(using: .utf8) else {
            print("[SomaAI] extract type=\(type.rawValue) — content is not valid UTF-8, returning raw text fallback")
            return SomaExtractionResponse(type: type.rawValue, date: nil, organization: nil, title: nil, confidence: 0.3, markers: nil, medications: nil, sections: [SomaSection(key: "Текст", value: text, order: 0)])
        }
        // First try: direct decode (the happy path).
        do {
            let direct = try JSONDecoder().decode(SomaExtractionResponse.self, from: data)
            return direct
        } catch {
            // Sprint 4.7u: log the first 20 bytes as hex so we can see BOM,
            // stray characters, or any other encoding issue that breaks
            // JSONDecoder. Often it's BOM or non-breaking space at the start.
            let head = data.prefix(20)
            let hex = head.map { String(format: "%02x", $0) }.joined(separator: " ")
            let headStr = String(data: head, encoding: .utf8) ?? "<non-utf8>"
            print("[SomaAI] extract type=\(type.rawValue) — direct decode failed: \(error.localizedDescription) | headBytes=\(hex) | headStr=\(headStr.debugDescription)")
        }
        // Sprint 4.7u: try to heal truncated JSON before regex fallback.
        // Models often hit the max_tokens cap mid-marker, e.g. trailing
        // "name":"Тромбоциты","value":"200"... is cut. We try adding
        // closing brackets to finish the array+object, then decode.
        if let healed = Self.tryHealTruncatedJSON(content, type: type) {
            print("[SomaAI] extract type=\(type.rawValue) — healed truncated JSON, got \(healed.markers?.count ?? 0) markers")
            return healed
        }
        // Sprint 4.7w: JSONSerialization with .fragmentsAllowed handles
        // partial JSON better than JSONDecoder. We extract the markers array
        // manually and synthesize a SomaExtractionResponse.
        if let partial = Self.partialJSONExtraction(content, type: type) {
            print("[SomaAI] extract type=\(type.rawValue) — partial JSON extraction got \(partial.markers?.count ?? 0) markers")
            return partial
        }
        // Second try: extract the first { … } block from the response. Some
        // models wrap JSON in "Here is the result: {…}" prose. We grab the
        // first { and the last } and try decoding that slice.
        // Sprint 4.9d: try multiple starting braces because LLMs sometimes
        // include `{` inside markdown ``` fences or in comment-like prose.
        if let lastBrace = content.lastIndex(of: "}") {
            var currentIdx = content.startIndex
            while let firstBrace = content.range(of: "{", range: currentIdx..<lastBrace)?.lowerBound,
                  firstBrace < lastBrace {
                let slice = String(content[firstBrace...lastBrace])
                if let sliceData = slice.data(using: .utf8) {
                    do {
                        let repaired = try JSONDecoder().decode(SomaExtractionResponse.self, from: sliceData)
                        print("[SomaAI] extract type=\(type.rawValue) — JSON repair succeeded at offset \(firstBrace) (\(slice.count) chars)")
                        return repaired
                    } catch {
                        // Continue trying the next `{`
                        // Print only first failure to avoid log spam
                        if firstBrace == content.firstIndex(of: "{") {
                            print("[SomaAI] extract type=\(type.rawValue) — slice repair at offset \(firstBrace) failed: \(error.localizedDescription)")
                        }
                    }
                }
                // Move past this brace
                currentIdx = content.index(after: firstBrace)
                if currentIdx >= lastBrace { break }
            }
        }
        // Third try: manual regex extraction for markers specifically.
        // If JSONDecoder fails but we can extract marker JSON snippets via
        // regex, build a partial SomaExtractionResponse manually.
        if let manual = Self.manualMarkerExtraction(content, type: type) {
            print("[SomaAI] extract type=\(type.rawValue) — manual regex extraction recovered \(manual.markers?.count ?? 0) markers")
            return manual
        }
        // Both attempts failed — try local regex first, then raw text.
        print("[SomaAI] extract decode failed for type \(type.rawValue) — falling back to LocalExtractor")
        let local = LocalExtractor.extract(text, type: type)
        print("[SomaAI] localExtract type=\(type.rawValue) → markers=\(local.markers?.count ?? 0), meds=\(local.medications?.count ?? 0), sections=\(local.sections?.count ?? 0), conf=\(local.confidence)")
        if local.sections?.isEmpty == false || local.markers?.isEmpty == false || local.medications?.isEmpty == false {
            return local
        }
        // Local also found nothing — return raw text so user can edit.
        let truncated = text.count > 3000 ? String(text.prefix(3000)) + "…[truncated]" : text
        return SomaExtractionResponse(
            type: type.rawValue, date: nil, organization: nil, title: nil,
            confidence: 0.3, markers: nil, medications: nil,
            sections: [SomaSection(key: "Сырой текст", value: truncated, order: 0)]
        )
    }

    // MARK: Step 3 — validate

    /// Deterministic validation: removes duplicate markers, clamps
    /// confidence, picks the better organisation between classify and
    /// extract outputs, and defaults empty `markers` arrays to nil.
    private func validate(extraction: SomaExtractionResponse, classification: SomaClassifyResponse, expectedType: DocumentType) -> SomaExtractionResponse {
        // 1. Deduplicate markers by name+value
        var seen = Set<String>()
        let deduped = extraction.markers?.filter { m in
            let key = m.name.lowercased() + "|" + m.value.lowercased()
            return seen.insert(key).inserted
        }
        // 2. Better organisation (prefer the longer one)
        let org = [extraction.organization, classification.organization]
            .compactMap { $0 }
            .max(by: { $0.count < $1.count })
        // 3. Confidence: average of two sources, clamped
        let conf = max(0.0, min(1.0, (extraction.confidence + classification.confidence) / 2.0))
        // 4. Drop empty payloads
        let meds = (extraction.medications?.isEmpty == false) ? extraction.medications : nil
        let secs = (extraction.sections?.isEmpty == false) ? extraction.sections : nil
        var marks = (deduped?.isEmpty == false) ? deduped : nil
        // 5. Type override: smartClassify is the source of truth.
        //    LLM often confuses 'Эпикриз выписной' (dischargeSummary)
        //    with 'Эпикриз' (epicrisis) in the extract step, even when
        //    we lock the prompt. Override back to what classify said
        //    so the document is saved with the right type. The user
        //    can still change it manually in the verification UI.
        let finalType = expectedType.rawValue
        if extraction.type != finalType {
            print("[SomaAI] validate: LLM returned type='\(extraction.type)' but classify said '\(finalType)' — overriding")
        }

        // 6. Sprint 4.7ao-pdf-5f: sections-as-markers fallback.
        //    If the LLM responded with `sections` (because it picked
        //    the unknown/clinical extractor instead of the lab
        //    extractor) but the sections actually look like lab
        //    markers (key = marker name, value = "X (норма: Y-Z)"
        //    pattern), convert them into SomaMarker entries so the
        //    user gets the data in the lab-marker UI instead of
        //    the generic section list.
        //
        //    The 14:59 log showed exactly this failure: 11 lab
        //    markers dumped as sections with keys like
        //    "Клетки плоского эпителия" and values like
        //    "единичные в препарате (норма: единичные в поле
        //    зрения)". The user saw markers=0, sections=11 even
        //    though the data was right there.
        //
        //    Conversion rules:
        //      - value matches "<X> (норма: <Y>)" → split on the
        //        "(норма: " boundary; X becomes the value, Y becomes
        //        the referenceRange.
        //      - value matches "<X> (norma: <Y>)" (Latin translit) —
        //        also accept.
        //      - if no "(норма:" match, store the entire value as
        //        the marker value with nil referenceRange.
        //      - computeFlag() is then used to derive the flag
        //        from value vs referenceRange, exactly like the
        //        manualMarkerExtraction path.
        if marks == nil, let secs = secs, finalType == DocumentType.labResult.rawValue {
            let converted = Self.sectionsAsMarkers(secs)
            if !converted.isEmpty {
                print("[SomaAI] validate: converted \(converted.count) sections-as-markers (LLM returned sections for a labResult)")
                marks = converted
            }
        }

        return SomaExtractionResponse(
            type: finalType,
            date: extraction.date,
            organization: org,
            title: extraction.title,
            confidence: conf,
            markers: marks,
            medications: meds,
            sections: secs
        )
    }

    /// Sprint 4.7ao-pdf-5f: convert a `[SomaSection]` array into a
    /// `[SomaMarker]` array when the LLM responded with sections
    /// instead of markers (e.g. smartClassify flipped to unknown
    /// and the generic extractor dumped the lab table as
    /// key/value sections). Used by `validate()` for documents
    /// where `expectedType == .labResult`.
    static func sectionsAsMarkers(_ sections: [SomaSection]) -> [SomaMarker] {
        // Patterns that identify a "value (норма: referenceRange)"
        // structure inside the section value field.
        let normaPatterns = [
            #"\s*\(норма:\s*(.+?)\)\s*$"#,         // "(норма: 4,2-5,6)"
            #"\s*\(норма\s*:\s*(.+?)\)\s*$"#,       // "норма :" (extra spaces)
            #"\s*\(norma:\s*(.+?)\)\s*$"#,         // Latin transliteration
        ]
        var out: [SomaMarker] = []
        for s in sections {
            // Skip sections that are clearly metadata, not lab rows.
            // Heuristic: skip if the key is one of the well-known
            // clinical-section headings (they would be noise here).
            let lowerKey = s.key.lowercased()
            let skipKeys: Set<String> = [
                "жалобы", "complaints", "анамнез", "anamnesis",
                "диагноз", "diagnosis", "лечение", "treatment",
                "рекомендации", "recommendations", "вывод", "conclusion",
                "операция", "операции", "surgery", "operation",
                "описание", "description", "заключение", "детали", "details",
                "модальность (modality)", "область (body region)",
                "куда (target)", "цель (reason)",
                "необходимые обследования (required tests)"
            ]
            if skipKeys.contains(lowerKey) { continue }

            // Try to extract "value (норма: refRange)" pattern.
            var value = s.value
            var reference: String? = nil
            for pat in normaPatterns {
                if let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]) {
                    let ns = s.value as NSString
                    if let m = re.firstMatch(in: s.value, range: NSRange(location: 0, length: ns.length)) {
                        let refCaptured = ns.substring(with: m.range(at: 1))
                        let valueMatch = ns.substring(with: NSRange(location: 0, length: m.range.location))
                        value = valueMatch.trimmingCharacters(in: .whitespaces)
                        reference = refCaptured.trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
            // If there's still a trailing ") (норма: ...)" we missed,
            // strip it from value.
            let flag = Self.computeFlag(value: value, reference: reference)
            out.append(SomaMarker(
                name: s.key,
                value: value,
                unit: nil,
                referenceRange: reference,
                flag: flag
            ))
        }
        return out
    }

    // MARK: Shared low-level chat call

    /// Single low-level LLM call. Used by every step of the pipeline.
    // Sprint 4.7e: provider + apiKey + endpoint parameters. Allows
    // sending to multiple providers from the same client.
    private func sendChat(
        messages: [[String: String]],
        temperature: Double,
        model: String? = nil,
        provider: APIProvider = .wormsoft,
        apiKey: String? = nil,
        endpoint: String? = nil
    ) async throws -> String {
        let activeKey = apiKey ?? self.apiKey(for: provider)
        guard !activeKey.isEmpty else { throw SomaAPIError.noAPIKey }
        let activeEndpoint = endpoint ?? (provider.baseURL + "/chat/completions")
        guard let url = URL(string: activeEndpoint) else { throw SomaAPIError.invalidEndpoint(activeEndpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(activeKey)", forHTTPHeaderField: "Authorization")
        // Sprint 4.7n: bumped from 15s to 30s. Reasoning models like
        // code/high (minimax-m3) need 5-15s on the first call from
        // iOS URLSession (cold TLS handshake + Apple ATS overhead).
        // Combined with 3-model chain, max 90s for extract step.
        request.timeoutInterval = 30
        let chosenModel = model ?? provider.defaultModel
        // Sprint 4.7m: request JSON output explicitly. Wormsoft code/high
        // (minimax-m3) and gemma4 both honor `response_format=json_object`
        // and stop wrapping their answers in ```json ... ``` blocks.
        // Verified 2026-07-09: cuts the JSON-repair code path in half and
        // matches the schema without leading/trailing fences.
        // Sprint 4.7u: max_tokens=8000 (was 6000 in 4.7ao-pdf-5d) — with
        // the header+body split the extract step now sees 2000+ chars of
        // OCR text and needs to emit JSON for 11+ markers with non-trivial
        // `unit` and `referenceRange` fields (e.g. "в поле зр." /
        // "0,00 - 3,00"). At 6000 the model was cutting off mid-marker
        // (we saw
        //   {"name":"Слизь","value":"небольшое кол-во","unit
        // — no closing : or value, decode failed, regex-fallback recovered
        // 11 markers). 8000 gives enough headroom for a full 15-marker
        // panel. Bump was 4000 -> 6000 in 4.7u (2026-07-09) when 6000
        // first looked sufficient.
        // (15 markers × ~120 chars/row = ~1.8KB JSON), and 30s timeout for
        // reasoning models like code/high (minimax-m3) which can take 5-15s
        // on the first call from iOS URLSession.
        let body: [String: Any] = [
            "model": chosenModel,
            "messages": messages,
            "temperature": temperature,
            "max_tokens": 8000,
            "response_format": ["type": "json_object"]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw SomaAPIError.invalidResponse }
        guard httpResponse.statusCode == 200 else { throw SomaAPIError.httpStatus(httpResponse.statusCode) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SomaAPIError.unparseableResponse
        }
        return content
    }

    /// Race sendChat against a timeout. Returns nil if the model hangs
    /// or throws — callers should treat that as a "vote lost" and
    /// continue without blocking the pipeline.
    private func sendChatWithTimeout(messages: [[String: String]], temperature: Double, seconds: Double = 12) async -> (vote: SomaClassifyResponse?, error: Error?) {
        do {
            let content = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.sendChat(messages: messages, temperature: temperature) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    throw CancellationError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            guard let data = content.data(using: .utf8) else {
                return (SomaClassifyResponse(type: DocumentType.unknown.rawValue, confidence: 0.0, organization: nil), nil)
            }
            if let resp = try? JSONDecoder().decode(SomaClassifyResponse.self, from: data) {
                return (resp, nil)
            }
            return (SomaClassifyResponse(type: DocumentType.unknown.rawValue, confidence: 0.0, organization: nil), nil)
        } catch {
            return (nil, error)
        }
    }

    /// Sends a user health question with filtered local context.
    func askConsultant(_ question: String, context: [String: String] = [:], language: String = "English") async throws -> String {
        guard !apiKey.isEmpty else {
            throw SomaAPIError.noAPIKey
        }

        guard let url = URL(string: chatEndpoint) else {
            throw SomaAPIError.invalidEndpoint(chatEndpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var systemPrompt = SomaPrompts.consultantSystem
        let langDirective = (language == "Русский" || language == "Russian" || language == "ru")
            ? "Reply in Russian."
            : "Reply in English."
        systemPrompt += "\n\nUSER LANGUAGE: \(langDirective)"
        if !context.isEmpty {
            // Numbered list with explicit IDs — keeps the model from
            // duplicating or paraphrasing marker names.
            var index = 1
            let contextLines = context.enumerated().map { _, kv -> String in
                defer { index += 1 }
                return "[\(index)] \(kv.key) => \(kv.value)"
            }.joined(separator: "\n")
            systemPrompt += "\n\n--- HEALTH PASSPORT FRAGMENTS (use ONLY these, do NOT invent) ---\n\(contextLines)\n--- END FRAGMENTS ---"
        } else {
            systemPrompt += "\n\nNO HEALTH PASSPORT FRAGMENTS ARE AVAILABLE — be honest and ask the user to add lab data first."
        }

        let messages: [[String: String]] = [
            ["role": "system", "content": systemPrompt],
            ["role": "user", "content": question]
        ]
        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages,
            "temperature": 0.2
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SomaAPIError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw SomaAPIError.httpStatus(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SomaAPIError.unparseableResponse
        }

        return content
    }
}

// MARK: - Errors
enum SomaAPIError: LocalizedError {
    case noAPIKey
    case invalidEndpoint(String)
    case invalidResponse
    case httpStatus(Int)
    case unparseableResponse

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "API key not configured. Go to Profile → Soma API Key."
        case .invalidEndpoint(let endpoint):
            return "Invalid API endpoint: \(endpoint)"
        case .invalidResponse:
            return "Invalid response from server."
        case .httpStatus(let code):
            switch code {
            case 401: return "401 Unauthorized — check your API key."
            case 404: return "404 Not Found — check your Base URL."
            case 429: return "429 Too Many Requests — slow down."
            default: return "Server returned \(code)."
            }
        case .unparseableResponse:
            return "Could not parse API response."
        }
    }
}

// MARK: - Prompts
enum SomaPrompts {
    // Sprint 4.7z: massively trimmed to fix LLM truncation. Old version
    // listed 50+ item names which caused reasoning models to spend tokens
    // on verbose prose. New version: schema + 3 examples + explicit length cap.
    static let labMarkerExtractor = """
Extract all lab markers (blood, urine, biochemistry, immunology, prescriptions) from the OCR text. Return ONLY a JSON object.

JSON schema:
{"markers":[{"name":"...","value":"...","unit":"...","referenceRange":"...","flag":"High|Low|Normal"}]}

Examples (mimic this exact shape, comma-decimals like 4,5):
1. CBC row "Эритроциты, RBC  4,5  4,2-5,6  10 в 12 ст./л" → {"name":"Эритроциты, RBC","value":"4,5","unit":"10 в 12 ст./л","referenceRange":"4,2-5,6","flag":"Normal"}
2. Biochemistry "Глюкоза 5,4 ммоль/л  3,3-5,5" → {"name":"Глюкоза","value":"5,4","unit":"ммоль/л","referenceRange":"3,3-5,5","flag":"Normal"}
3. Out-of-range "Лейкоциты 12,5  10 в 9 ст./л  4,0-9,0" → {"name":"Лейкоциты","value":"12,5","unit":"10 в 9 ст./л","referenceRange":"4,0-9,0","flag":"High"}

Rules:
- Compare value to referenceRange: in range → "Normal", above → "High", below → "Low". Skip flag if no reference.
- One marker per row. Do not collapse.
- If name only, value=null, flag=null. If value+name, flag required.
- Scan the whole OCR text (it may be a long document).
- Output ≤2000 characters of valid JSON. No markdown, no prose, no comments.
- Use Russian for names when the document is in Russian.
"""

    static let consultantSystem = """
You are Soma AI, a health data organizer. You help the user understand their own medical records and prepare questions for a licensed physician.
Rules:
1. Never diagnose, prescribe, or recommend changing treatment.
2. Base answers ONLY on the provided Health Passport fragments — do NOT invent, guess, or duplicate any marker that is not explicitly listed in the fragments. If the user asks for a marker that is missing from the fragments, say so.
3. When listing markers, copy names and values EXACTLY as they appear in the fragments. Do not split one value into multiple markers.
4. Reply in the language the user writes in (Russian or English). Match the user's script.
5. If data is insufficient, say so explicitly and suggest discussing with a doctor.
6. Always include a short disclaimer: "This is a data summary, not medical advice. Consult a licensed physician." (or its Russian equivalent: "Это сводка данных, а не медицинский совет. Проконсультируйтесь с врачом.")
7. Prefer asking the user clarifying questions over guessing.
"""

    // MARK: - 3-step pipeline prompts

    /// Step 1: classify a raw OCR text into one of 9 document types.
    /// Returns minimal JSON so the LLM can't drift into extraction.
    static let documentClassifier = """
You are a medical document classifier. Read the OCR text and pick the SINGLE most likely type.
Return ONLY this JSON shape (no markdown, no commentary):
{"type": "<one of: labResult|epicrisis|prescription|referral|consultation|dischargeSummary|imagingReport|vaccination|unknown>", "confidence": 0.0-1.0, "organization": "<clinic/hospital name or null>"}

Classification rules (RU + EN, case-insensitive):
  - labResult        : the document lists numerical lab values with reference ranges, units, or flags (analiz, анализ, кровь, моча, биохимия, CBC, urinalysis).
  - epicrisis        : "эпикриз" / "выписной эпикриз" / discharge summary with diagnosis + treatment course.
  - prescription     : "рецепт", "назначения", "Rp.", "S.", drug names with dose+frequency+duration. No lab values.
  - referral         : "направление", "направить к", "прошу обследовать", referral letter to another doctor or lab.
  - consultation     : "консультация", "заключение специалиста", "осмотр", specialist's diagnostic note without hospitalisation.
  - dischargeSummary : "выписка", "выписной эпикриз" at end of hospitalisation, with final diagnosis and recommendations.
  - imagingReport    : "рентген", "КТ", "МРТ", "УЗИ", "ЭКГ", "ЭхоКГ", imaging conclusion.
  - vaccination      : "прививка", "вакцинация", vaccine name + date + lot.
  - unknown          : none of the above matches confidently.

EMBEDDED DATA RULE (very important for Russian выписные эпикризы):
  If the text contains BOTH a clinical narrative header
  (эпикриз, выписной эпикриз, протокол операции, осмотр, консультация, консилиум,
   выписка, рекомендации, диагноз, жалобы, анамнез, лечение, операции)
  AND embedded lab-style data
  (Изосерология, Анализ крови, ОАК, ОАМ, биохимия, группа крови, Rh, резус-фактор,
   фенотип, антиген, антитела, лейкоциты, гемоглобин, эритроциты, глюкоза, холестерин),
  classify as the CLINICAL document (epicrisis / dischargeSummary / consultation).
  The lab data is a sub-section, not the document type.
  Set confidence >= 0.7 in that case.

Tie-breaker: if BOTH lab values AND clinical notes (diagnosis, recommendations) are present AND no narrative header is visible, prefer the type that dominates by character count.

RECOGNITION UNCERTAINTY:
  - If the OCR is very short (< 80 chars) or has many junk lines (duplicated headers, isolated digits like "934)", "714", "11:161"), return confidence <= 0.4.
  - If you see a strong narrative header (Эпикриз, Выписка, Осмотр) somewhere in the first 30% of the text, treat the document as that type with confidence >= 0.7 even if the rest is messy.
  - Return confidence = 0.0 ONLY if you genuinely cannot pick a type.

If the OCR text is too short (< 50 chars) or unreadable, return type="unknown" and confidence=0.0.
"""

    /// Step 2 — prescriptions: drug list with doses.
    static let prescriptionExtractor = """
You are a strict medical prescription parser. Extract the prescribed drugs from the OCR text.
Return ONLY this JSON (no markdown):
{
  "type": "prescription",
  "date": "YYYY-MM-DD or null",
  "organization": "clinic name or null",
  "title": "short title or null",
  "confidence": 0.0-1.0,
  "medications": [
    {"name": "drug name", "dose": "e.g. 500 mg or null", "frequency": "e.g. 3 раза в день or null", "duration": "e.g. 7 дней or null", "route": "oral/внутривенно/etc or null"}
  ]
}

Rules:
  - Include EVERY drug you can see, even if dose is missing (use null for unknown fields).
  - Do NOT include lab values or diagnoses here.
  - If you find drug names in the text, ALWAYS return them. Returning an empty medications
    array when names are visible is a bug. Use null for fields you cannot read.
  - If the OCR is genuinely too short or has no drug names, return "medications": [] and confidence=0.2.
  - Scan the WHOLE text, not just the first lines.
"""

    /// Step 2 — epicrisis / consultation / discharge: free-form sections.
    /// The `forType` parameter is the DocumentType we passed in based on
    /// regexClassify + smartClassify. We lock the LLM to use exactly that
    /// type in its JSON response — otherwise the LLM often confuses
    /// 'Эпикриз выписной' (Discharge) with 'Эпикриз' (general Epicrisis),
    /// making a dischargeSummary document get saved as epicrisis.
    /// If smartClassify was wrong, the user can correct it manually in
    /// the verification UI; we don't want LLM to silently override it.
    static func epicrisisExtractor(forType: DocumentType) -> String {
        let allowedType = forType.rawValue
        let typeRule: String
        switch forType {
        case .dischargeSummary:
            typeRule = """
            You MUST set "type": "dischargeSummary". The document is a
            discharge summary (выписной эпикриз / выписка). DO NOT set
            type to "epicrisis" even though the word 'эпикриз' appears
            in the document title — 'выписной эпикриз' is the Russian
            name for a discharge summary, not a general epicrisis.
            """
        case .epicrisis:
            typeRule = """
            You MUST set "type": "epicrisis". The document is a general
            epicrisis (stage-of-treatment summary). DO NOT set type to
            "dischargeSummary" — only set that if you see 'выписной',
            'выписка', or 'Discharge summary'.
            """
        case .consultation:
            typeRule = """
            You MUST set "type": "consultation". The document is a
            consultation / specialist visit (консультация / осмотр).
            """
        default:
            typeRule = "Set type to one of: epicrisis, consultation, dischargeSummary."
        }
        return """
You are a strict medical record parser. Extract the named clinical sections from the OCR text.
Return ONLY this JSON (no markdown):
{
  "type": "\(allowedType)",
  "date": "YYYY-MM-DD or null",
  "organization": "clinic name or null",
  "title": "short title or null",
  "confidence": 0.0-1.0,
  "sections": [
    {"key": "section name", "value": "full section text", "order": 0}
  ]
}

CRITICAL TYPE RULE:
\(typeRule)

CRITICAL CONTENT RULE: Never return an empty sections array if the OCR text is substantial (>200 chars).
If the document is a hybrid (e.g. выписной эпикриз with embedded Изосерология block, or a
clinical narrative that starts with a lab-result header), ALWAYS extract the clinical
content into the matching section keys below. Embedded lab values, blood-group data, or
imaging snippets belong in a 'Лабораторные данные' / 'Lab data' sub-section, NOT skipped.
If you genuinely cannot find any of the listed sections, put the entire visible clinical
text into one 'Детали' / 'Details' section so the user can save the document. Returning
sections:[] for a multi-page document is a bug.

Common section keys (use these exact names when present, otherwise the original heading):
  Жалобы / Complaints
  Анамнез / Anamnesis
  Анамнез заболевания / History of present illness
  Объективный статус / Objective status
  Status localis
  Диагноз / Diagnosis
  Основной диагноз / Primary diagnosis
  Сопутствующий диагноз / Comorbidities
  Лечение / Treatment
  Операция / Surgery / Operation
  Рекомендации / Recommendations
  Вывод / Conclusion
  Лабораторные данные / Lab data
  Детали / Details

Rules:
  - Include a section ONLY if there is actual text for it. Skip empty ones.
  - If a section name contains line breaks or newlines, collapse them into spaces.
  - 'order' is the reading order: 0, 1, 2, ...
  - Scan the WHOLE text. Do not stop at the first sub-section.
"""
    }

    /// Step 2 — referral: target + required tests.
    static let referralExtractor = """
You are a strict medical referral parser. Extract where the patient is being referred, by whom, and for what reason.
Return ONLY this JSON (no markdown):
{
  "type": "referral",
  "date": "YYYY-MM-DD or null",
  "organization": "issuing clinic or null",
  "title": "short title or null",
  "confidence": 0.0-1.0,
  "sections": [
    {"key": "Куда (target)", "value": "doctor or department name", "order": 0},
    {"key": "Цель (reason)", "value": "reason for referral", "order": 1},
    {"key": "Необходимые обследования (required tests)", "value": "list of tests or examination", "order": 2}
  ]
}

CRITICAL: Never return empty sections for a document with >200 chars of text.
If you cannot find a 'Куда' / 'Цель' section, but the text contains visible
referral context (clinic name, doctor name, symptoms), put that text into a
'Детали' / 'Details' section so the user can still save the document. Empty
sections on a real referral is a bug.

If a section is missing, omit it. If OCR is too short, return empty sections and confidence=0.2.
"""

    /// Step 2 — imaging report (X-ray, CT, MRI, ultrasound, ECG).
    static let imagingExtractor = """
You are a strict imaging report parser. Extract the imaging modality, body region, conclusion and findings.
Return ONLY this JSON (no markdown):
{
  "type": "imagingReport",
  "date": "YYYY-MM-DD or null",
  "organization": "clinic name or null",
  "title": "e.g. 'КТ грудной клетки' or null",
  "confidence": 0.0-1.0,
  "sections": [
    {"key": "Модальность (modality)", "value": "КТ / МРТ / рентген / УЗИ / ЭКГ", "order": 0},
    {"key": "Область (body region)", "value": "body region", "order": 1},
    {"key": "Описание (description)", "value": "radiologist's description", "order": 2},
    {"key": "Заключение (conclusion)", "value": "final conclusion", "order": 3}
  ]
}

CRITICAL: Never return empty sections for a document with >200 chars of text.
If you cannot find the modality or conclusion, but the text describes a
radiology / imaging study, put the visible text into a 'Детали' / 'Details'
section so the user can still save the document.

If a section is missing, omit it. If OCR is too short, return empty sections and confidence=0.2.
"""

    /// Step 2 — vaccination card.
    static let vaccinationExtractor = """
You are a strict vaccination record parser.
Return ONLY this JSON (no markdown):
{
  "type": "vaccination",
  "date": "YYYY-MM-DD or null",
  "organization": "clinic name or null",
  "title": "vaccine name or null",
  "confidence": 0.0-1.0,
  "sections": [
    {"key": "Вакцина (vaccine)", "value": "vaccine name", "order": 0},
    {"key": "Серия (lot)", "value": "lot number or null", "order": 1},
    {"key": "Доза (dose)", "value": "e.g. 0.5 ml or null", "order": 2},
    {"key": "Реакция (reaction)", "value": "post-vaccination reaction or null", "order": 3}
  ]
}
"""

    /// Step 2 — unknown document: dump as raw key/value sections.
    static let genericExtractor = """
You are a strict medical document parser. The document type is unknown, so extract whatever key/value pairs you can find.
Return ONLY this JSON (no markdown):
{
  "type": "unknown",
  "date": "YYYY-MM-DD or null",
  "organization": "clinic or hospital name or null",
  "title": "best guess at document title or null",
  "confidence": 0.0-1.0,
  "sections": [
    {"key": "<heading>", "value": "<body>", "order": 0}
  ]
}

Use the original section headings. If there are no headings, split the text into 2-3 logical sections (Верх, Середина, Низ is fine). Keep the order they appear in the text.
If OCR is too short (< 50 chars), return empty sections and confidence=0.0.
"""
}


// MARK: - Sprint 4.7u: truncated JSON healer

extension SomaAPIClient {
    /// Sprint 4.7v: strip markdown code fences that reasoning models add
    /// even when `response_format=json_object` is set. `code/high`
    /// (minimax-m3) and `qwen3` both wrap JSON in ```json\n{...}\n``` blocks.
    /// We strip any leading/trailing ``` lines and any ```json / ``` markers.
    static func stripMarkdownFences(_ s: String) -> String {
        var out = s
        // Remove ```json or ``` markers (with optional language tag)
        // at the start of the string.
        while out.hasPrefix("```") {
            // Drop first line (up to and including newline)
            if let nlRange = out.range(of: "\n") {
                out = String(out[nlRange.upperBound...])
            } else {
                out = ""
                break
            }
        }
        // Remove trailing ``` (and any whitespace before it).
        if let range = out.range(of: "```", options: .backwards) {
            out = String(out[..<range.lowerBound])
        }
        // Trim BOM, whitespace, and stray newlines around the JSON.
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if out.hasPrefix("\u{FEFF}") {
            out = String(out.dropFirst())
        }
        return out
    }

    /// Sprint 4.7u / 4.7ao-pdf-5d-bis: if the LLM response was truncated
    /// mid-marker (hit the `max_tokens` cap before closing the array),
    /// try to close it manually. The truncated text looks like
    ///     {"markers":[{"name":"X","value":"1"},{"name":"Y","valu
    /// (cut mid-key).
    ///
    /// Sprint 4.7u original: walk back 1..20 chars, append `}]}`,
    /// decode. This works for clean cuts inside the LAST object but
    /// not for cuts deeper than 20 chars.
    ///
    /// Sprint 4.7ao-pdf-5d-bis: extend the walk-back to 200 chars
    /// (enough to skip past a couple of complete marker objects and
    /// the separator `,` after the truncation point). The 4.7ao-pdf-5d
    /// header+body split produced 2000+ chars of OCR text and the LLM
    /// at max_tokens=6000 was cutting off mid-marker at depth ~50
    /// chars (we saw
    ///   {"name":"Слизь","value":"небольшое кол-во","unit
    /// — 50 chars from the end). 200-char walk-back covers that and
    /// gives us the SAME decode success rate as 4.7u had on the
    /// shorter documents.
    static func tryHealTruncatedJSON(_ content: String, type: DocumentType) -> SomaExtractionResponse? {
        // Find the start of the JSON (first `{`).
        guard let firstBrace = content.firstIndex(of: "{") else { return nil }
        let prefix = String(content[firstBrace...])
        // Sprint 4.7ao-pdf-5d-bis: bumped 20 -> 200 to handle deeper
        // cuts. The original 20 was enough for 4.7u's pre-4.7ao-pdf-5d
        // inputs (~1500 chars / 11 markers) but the 4.7ao-pdf-5d
        // header+body OCR (~2000 chars) is hitting the max_tokens=6000
        // cap deeper into the response.
        for drop in 0..<200 {
            let endIdx = prefix.endIndex
            let cutIdx = prefix.index(endIdx, offsetBy: -drop, limitedBy: prefix.startIndex) ?? prefix.startIndex
            let truncated = String(prefix[..<cutIdx])
            // Try several closing patterns: `}]}`, `,}]}` (with trailing comma
            // stripped), `]}`.
            let closures = [
                "}]}",  // array + root
                "]",    // just array (root already closed?)
                "",     // already complete
            ]
            for closure in closures {
                let candidate = truncated + closure
                if let data = candidate.data(using: .utf8),
                   let parsed = try? JSONDecoder().decode(SomaExtractionResponse.self, from: data) {
                    if let markers = parsed.markers, markers.count >= 3 {
                        return parsed
                    }
                }
            }
        }
        return nil
    }

    /// Sprint 4.7w: parse truncated JSON by closing brackets + walking back
    /// to find the last `}` before the truncation point. We do NOT need to
    /// decode the whole response — just find the largest valid prefix that
    /// ends with a complete object in the markers array.
    static func partialJSONExtraction(_ content: String, type: DocumentType) -> SomaExtractionResponse? {
        // Sprint 4.7y: walk back from the end, but FAST — skip from `}` to `}`
        // and only try cutting at object boundaries. Then close `]}` and decode.
        guard content.contains("\"markers\"") else { return nil }
        // Collect all positions of `}` in content.
        var closeBracePositions: [String.Index] = []
        var i = content.startIndex
        while i < content.endIndex {
            if content[i] == "}" { closeBracePositions.append(i) }
            i = content.index(after: i)
        }
        // Try from the LAST `}` backwards. We want the largest prefix that
        // ends with a complete marker object.
        for pos in closeBracePositions.reversed() {
            let prefix = String(content[...pos]) + "]}"
            if let data = prefix.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(SomaExtractionResponse.self, from: data),
               let markers = parsed.markers, markers.count >= 3 {
                return parsed
            }
        }
        return nil
    }
}

// MARK: - Sprint 4.9d: manual marker extraction fallback

extension SomaAPIClient {
    /// Sprint 4.9d: if JSONDecoder fails (LLM produced truncated or
    /// malformed JSON), try to extract marker objects via regex directly
    /// from the raw LLM response text. Handles the common pattern:
    ///     {"name": "...", "value": "...", "unit": "...", ...}
    static func manualMarkerExtraction(_ content: String, type: DocumentType) -> SomaExtractionResponse? {
        // Look for marker-like JSON objects.
        // Pattern: {"name": "X", "value": "Y", ...}
        let pattern = #"\{\s*"name"\s*:\s*"([^"]+)"\s*,\s*"value"\s*:\s*"([^"]*)"(?:\s*,\s*"unit"\s*:\s*"([^"]*)")?(?:\s*,\s*"referenceRange"\s*:\s*"([^"]*)")?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return nil }

        var markers: [SomaMarker] = []
        for m in matches {
            let name = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 2))
            // groups 3, 4 may not be present
            let unit: String? = m.range(at: 3).location == NSNotFound ? nil : ns.substring(with: m.range(at: 3))
            let range: String? = m.range(at: 4).location == NSNotFound ? nil : ns.substring(with: m.range(at: 4))
            // Sprint 4.7x: compute flag from value vs referenceRange, so the
            // UI can color markers even when LLM JSON decode failed. We
            // parse "4,2 - 5,6" / "< 5,6" / "> 10" / "0,0 - 1,0" patterns
            // and compare the numeric value.
            let flag = Self.computeFlag(value: value, reference: range)
            markers.append(SomaMarker(
                name: name, value: value, unit: unit,
                referenceRange: range, flag: flag
            ))
        }
        // Also try to extract date/title if present
        let datePattern = #""date"\s*:\s*"([^"]+)""#
        let dateRegex = try? NSRegularExpression(pattern: datePattern)
        let date = dateRegex?.firstMatch(in: content, range: NSRange(location: 0, length: ns.length))
            .flatMap { ns.substring(with: $0.range(at: 1)) }
        let titlePattern = #""title"\s*:\s*"([^"]+)""#
        let titleRegex = try? NSRegularExpression(pattern: titlePattern)
        let title = titleRegex?.firstMatch(in: content, range: NSRange(location: 0, length: ns.length))
            .flatMap { ns.substring(with: $0.range(at: 1)) }
        let orgPattern = #""organization"\s*:\s*"([^"]+)""#
        let orgRegex = try? NSRegularExpression(pattern: orgPattern)
        let org = orgRegex?.firstMatch(in: content, range: NSRange(location: 0, length: ns.length))
            .flatMap { ns.substring(with: $0.range(at: 1)) }

        return SomaExtractionResponse(
            type: type.rawValue, date: date, organization: org, title: title,
            confidence: 0.8,  // partial recovery, slightly lower
            markers: markers, medications: nil, sections: nil
        )
    }

    /// Sprint 4.7x: parse a reference range string like "4,2 - 5,6" or
    /// "< 5,6" or "> 10" and compare against a numeric value. Returns
    /// "Normal", "High", or "Low". Returns nil if reference is missing
    /// or the value is not a number.
    static func computeFlag(value: String, reference: String?) -> String? {
        // 5d-twentieth: re-ordered text rules. Trace patterns
        // ('небольшое', 'единичные', 'немного', 'следы') MUST be
        // checked BEFORE positive patterns, because 'небольшое'
        // contains 'большое' as a substring. Also removed 'большое'
        // from positive patterns — it's ambiguous and never used
        // alone in lab reports.
        let valueLower = value.lowercased().trimmingCharacters(in: .whitespaces)
        let refLower = (reference ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        // 0. Trace / small / morphology patterns -> Normal
        //    (must come FIRST so 'небольшое' doesn't match 'большое')
        let tracePatterns = [
            "небольшое", "единичные", "мало", "немного", "следы",
            "trace", "small", "few", "гиалиновые", "неизмененные",
            "прозрачная", "соломенно"
        ]
        for p in tracePatterns where valueLower.contains(p) || refLower.contains(p) {
            return "Normal"
        }
        // 1. Negative / absence patterns -> Normal
        let negativePatterns = [
            "отрицательно", "отсутствуют", "не обнаружено", "не обнаружен",
            "не выявлено", "не найдено", "нет", "негативно", "negative",
            "neg", "absent", "not detected"
        ]
        for p in negativePatterns where valueLower.contains(p) || refLower.contains(p) {
            return "Normal"
        }
        // 2. Positive / present patterns -> High
        let positivePatterns = [
            "положительно", "обнаружено", "обнаружен", "выявлено",
            "присутствуют", "есть", "позитивно", "positive", "pos",
            "detected", "present", "значительное"
        ]
        for p in positivePatterns where valueLower.contains(p) {
            return "High"
        }
        // 3. Now try numeric path
        guard let reference = reference, !reference.isEmpty else { return nil }
        // 5d-twentieth: extract first number from value. PDFKit
        // continuation merge sometimes yields '0,6
        // микроальбуминурия; макроальбуминурия' (alpha). The number
        // is the real value — parse with regex.
        let extractedNum = Self.extractFirstNumber(from: value)
        guard let num = extractedNum else { return nil }
        // 5d-nineteenth: handle value="0-1" with range="0,00 - 3,00".
        // PDFKit sometimes emits small integer ranges as values.
        // If value looks like a tiny range (A - B where A and B are
        // numbers and B < 100), pick the larger endpoint.
        if num < 0 || num > 100000 { return nil }  // sanity
        return computeFlagForNumber(num: num, reference: reference)
    }

    /// 5d-twentieth: extract first decimal/integer from a string
    /// (handles '0,6 микроальбуминурия; макроальбуминурия' -> 0.6).
    /// Returns nil if no number found.
    private static func extractFirstNumber(from s: String) -> Double? {
        let normalized = s.replacingOccurrences(of: ",", with: ".")
        let pattern = #"-?\d+(?:\.\d+)?"#
        if let re = try? NSRegularExpression(pattern: pattern) {
            let ns = normalized as NSString
            let range = NSRange(location: 0, length: ns.length)
            if let m = re.firstMatch(in: normalized, range: range) {
                let str = ns.substring(with: m.range)
                return Double(str)
            }
        }
        // Fallback: maybe value is itself a range "0-1" with no spaces.
        let dashParts = normalized
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .components(separatedBy: "-")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        if dashParts.count == 2,
           let v0 = Double(dashParts[0]), let v1 = Double(dashParts[1]),
           v0 >= 0, v1 >= 0, v1 < 100 {
            return max(v0, v1)
        }
        return Double(normalized)
    }

    /// 5d-nineteenth: extracted numeric flag computation
    /// (so we can call it for both raw value and value-range cases).
    private static func computeFlagForNumber(num: Double, reference: String) -> String? {
        // Parse "< 5.6", "> 10", "4.2 - 5.6", "0.0 - 1.0"
        let ref = reference.replacingOccurrences(of: ",", with: ".")
        // Normalize dashes: "4.2-5.6" → "4.2 - 5.6" (also "–" en-dash, "—" em-dash)
        let refNorm = ref
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "-", with: " - ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        // Range: "A - B"
        if let dashRange = refNorm.range(of: " - ") {
            let lowStr = String(refNorm[refNorm.startIndex..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
            let highStr = String(refNorm[dashRange.upperBound..<refNorm.endIndex]).trimmingCharacters(in: .whitespaces)
            if let low = Double(lowStr), let high = Double(highStr) {
                if num < low { return "Low" }
                if num > high { return "High" }
                return "Normal"
            }
        }
        // Less than: "< 5.6" (also "≤5.6")
        if refNorm.contains("<") || refNorm.contains("≤") {
            let limStr = refNorm.replacingOccurrences(of: "<", with: "")
                .replacingOccurrences(of: "≤", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let lim = Double(limStr) { return num < lim ? "Normal" : "High" }
        }
        // Greater than: "> 10" (also "≥10")
        if refNorm.contains(">") || refNorm.contains("≥") {
            let limStr = refNorm.replacingOccurrences(of: ">", with: "")
                .replacingOccurrences(of: "≥", with: "")
                .trimmingCharacters(in: .whitespaces)
            if let lim = Double(limStr) { return num > lim ? "Normal" : "Low" }
        }
        return nil
    }
}
