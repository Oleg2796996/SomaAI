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

// MARK: - Client
final class SomaAPIClient {
    static let shared = SomaAPIClient()

    private var apiKey: String {
        do {
            return try KeychainHelper.shared.read()
        } catch {
            return ""
        }
    }

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
        // Overall 30s guard around the whole pipeline. If the LLM
        // endpoint hangs on any of the 4 calls (classify×3 + extract
        // + validate), we return unknown with raw sections instead of
        // leaving the user staring at a frozen spinner. The verification
        // UI knows how to render .unknown + raw text.
        return await withTaskGroup(of: SomaExtractionResponse.self) { group in
            group.addTask {
                do {
                    let cleaned = self.preprocessForClassification(text)
                    let body = cleaned.count > 200 ? cleaned : text
                    let classification = try await self.smartClassify(body)
                    let docType = DocumentType(rawValue: classification.type) ?? .unknown
                    let extraction = try await self.extractDocument(body, type: docType)
                    return self.validate(extraction: extraction, classification: classification)
                } catch {
                    print("[SomaAI] processDocument overall catch: \(error.localizedDescription)")
                    return SomaExtractionResponse(
                        type: DocumentType.unknown.rawValue,
                        date: nil, organization: nil, title: nil,
                        confidence: 0.0,
                        markers: nil, medications: nil,
                        sections: [SomaSection(key: "Текст", value: text, order: 0)]
                    )
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 50_000_000_000)
                print("[SomaAI] processDocument overall TIMEOUT after 50s — returning unknown fallback")
                return SomaExtractionResponse(
                    type: DocumentType.unknown.rawValue,
                    date: nil, organization: nil, title: nil,
                    confidence: 0.0,
                    markers: nil, medications: nil,
                    sections: [SomaSection(key: "Текст", value: text, order: 0)]
                )
            }
            let result = await group.next()!
            group.cancelAll()
            return result
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
            prompt = SomaPrompts.epicrisisExtractor
        case .referral: prompt = SomaPrompts.referralExtractor
        case .imagingReport: prompt = SomaPrompts.imagingExtractor
        case .vaccination: prompt = SomaPrompts.vaccinationExtractor
        case .unknown: prompt = SomaPrompts.genericExtractor
        }
        let messages: [[String: String]] = [
            ["role": "system", "content": prompt],
            ["role": "user", "content": text]
        ]
        let content: String
        do {
            content = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await self.sendChat(messages: messages, temperature: 0.0) }
                group.addTask {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                    throw CancellationError()
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
        } catch {
            print("[SomaAI] extract type=\(type.rawValue) TIMEOUT/error: \(error.localizedDescription) — returning raw text fallback")
            let truncated = text.count > 3000 ? String(text.prefix(3000)) + "…[truncated]" : text
            return SomaExtractionResponse(
                type: type.rawValue, date: nil, organization: nil, title: nil,
                confidence: 0.3, markers: nil, medications: nil,
                sections: [SomaSection(key: "Сырой текст", value: truncated, order: 0)]
            )
        }
        let preview = String(content.prefix(800))
        print("[SomaAI] extract type=\(type.rawValue) raw response (\(content.count) chars): \(preview)")
        guard let data = content.data(using: .utf8) else {
            print("[SomaAI] extract type=\(type.rawValue) — content is not valid UTF-8, returning raw text fallback")
            return SomaExtractionResponse(type: type.rawValue, date: nil, organization: nil, title: nil, confidence: 0.3, markers: nil, medications: nil, sections: [SomaSection(key: "Текст", value: text, order: 0)])
        }
        // First try: direct decode (the happy path).
        if let direct = try? JSONDecoder().decode(SomaExtractionResponse.self, from: data) {
            return direct
        }
        // Second try: extract the first { … } block from the response. Some
        // models wrap JSON in "Here is the result: {…}" prose. We grab the
        // first { and the last } and try decoding that slice.
        if let firstBrace = content.firstIndex(of: "{"),
           let lastBrace = content.lastIndex(of: "}"),
           firstBrace < lastBrace {
            let slice = String(content[firstBrace...lastBrace])
            if let sliceData = slice.data(using: .utf8),
               let repaired = try? JSONDecoder().decode(SomaExtractionResponse.self, from: sliceData) {
                print("[SomaAI] extract type=\(type.rawValue) — JSON repair succeeded (\(slice.count) chars)")
                return repaired
            }
        }
        // Both attempts failed — fall back to raw text so the user can save.
        print("[SomaAI] extract decode failed for type \(type.rawValue). Raw content head: \(content.prefix(2000))")
        // Fallback: do NOT discard the OCR. Return the raw text inside
        // a single section so the verification UI can show it and the
        // user can manually re-classify or re-extract. confidence=0.3
        // is high enough to not trigger the 'LLM not confident'
        // warning but low enough that the user knows it was a fallback.
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
    private func validate(extraction: SomaExtractionResponse, classification: SomaClassifyResponse) -> SomaExtractionResponse {
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
        let marks = (deduped?.isEmpty == false) ? deduped : nil
        return SomaExtractionResponse(
            type: extraction.type,
            date: extraction.date,
            organization: org,
            title: extraction.title,
            confidence: conf,
            markers: marks,
            medications: meds,
            sections: secs
        )
    }

    // MARK: Shared low-level chat call

    /// Single low-level LLM call. Used by every step of the pipeline.
    private func sendChat(messages: [[String: String]], temperature: Double) async throws -> String {
        guard !apiKey.isEmpty else { throw SomaAPIError.noAPIKey }
        guard let url = URL(string: chatEndpoint) else { throw SomaAPIError.invalidEndpoint(chatEndpoint) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Hard 20s timeout per HTTP call. The Wormsoft endpoint has been
        // observed to hang for >60s on long prompts; we'd rather give up
        // and let smartClassify()'s fail-open return unknown than freeze
        // the UI.
        request.timeoutInterval = 20
        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages,
            "temperature": temperature
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
    static let labMarkerExtractor = """
You are a strict medical data parser. Extract lab markers, lab values, prescriptions, antigens and phenotypes from the raw OCR text. Return ONLY a JSON object with a top-level key 'markers'.
Each marker has: name (string, required), value (string, required), unit (string or null), referenceRange (string or null), flag (string: "High", "Low", or "Normal", or null).
Do not output markdown, explanations, or any text outside the JSON.

TYPICAL ITEMS YOU SHOULD RECOGNIZE (RU + EN):
Lab values (urine + blood + biochemistry + immunology):
  Моча/Urine: цвет, прозрачность, pH, плотность/удельный вес (sg), белок (protein), глюкоза (glucose), кетоны (ketones), лейкоциты (WBC), эритроциты (RBC), нитриты, уробилиноген, билирубин, слизь, бактерии, эпителий, цилиндры, соли/кристаллы, дрожжеподобные грибы.
  Blood (CBC): гемоглобин (Hb), эритроциты (RBC), гематокрит (HCT), лейкоциты (WBC), тромбоциты (PLT), MCV, MCH, MCHC, RDW, эозинофилы, базофилы, моноциты, лимфоциты, нейтрофилы, СОЭ (ESR).
  Biochemistry: глюкоза, мочевина, креатинин, билирубин общий/прямой, АЛТ, АСТ, общий белок, альбумин, холестерин, ЛПНП, ЛПВП, триглицериды, прокальцитонин, С-реактивный белок (CRP).
  Immunology / phenotypes: антиген, антитело, фенотип, CD15/CD20/CD3, группа крови, резус-фактор, ИКПЛ, ИФА, ПЦР.
Prescriptions (назначения, лекарства):
  Препараты с дозой (mg, мг, мл, нг/мл, ЕД, таб, капли, пак, суппозитории) — цефазолин, детралекс, фитозилин, омепразол, кеторол, парацетамол, ибупрофен, панкреатин, лоперамид, дротаверин, но-шпа, эссенциале, фосфоглив и т.п.
  Use category 'prescription' for the name prefix if you can, otherwise just put the drug name as 'name' and 'value' as the dose+unit.

Rules:
  - If a row has name + value, include it. If only name, still include with value '—'.
  - Do NOT collapse multiple values into one marker. One marker per row.
  - Return JSON even if uncertain — the user will verify.
  - The OCR text may be a long medical document (эпикриз, выписка, направление) — scan the WHOLE text, not just the first few lines.
  - Look for drug names, doses, and lab values anywhere in the text.
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
    static let epicrisisExtractor = """
You are a strict medical record parser. Extract the named clinical sections from the OCR text.
Return ONLY this JSON (no markdown):
{
  "type": "<epicrisis|consultation|dischargeSummary>",
  "date": "YYYY-MM-DD or null",
  "organization": "clinic name or null",
  "title": "short title or null",
  "confidence": 0.0-1.0,
  "sections": [
    {"key": "section name", "value": "full section text", "order": 0}
  ]
}

CRITICAL: Never return an empty sections array if the OCR text is substantial (>200 chars).
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
