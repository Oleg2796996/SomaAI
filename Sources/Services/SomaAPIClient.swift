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
        // Step 1: classify
        let classification = try await classifyDocument(text)
        let docType = DocumentType(rawValue: classification.type) ?? .unknown
        // Step 2: extract (type-aware)
        let extraction = try await extractDocument(text, type: docType)
        // Step 3: validate + normalise
        return validate(extraction: extraction, classification: classification)
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
        guard let data = content.data(using: .utf8) else {
            return SomaClassifyResponse(type: DocumentType.unknown.rawValue, confidence: 0.0, organization: nil)
        }
        do {
            return try JSONDecoder().decode(SomaClassifyResponse.self, from: data)
        } catch {
            print("[SomaAI] classify decode failed: \(error.localizedDescription)")
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
        let content = try await sendChat(messages: messages, temperature: 0.1)
        guard let data = content.data(using: .utf8) else {
            return SomaExtractionResponse(type: type.rawValue, date: nil, organization: nil, title: nil, confidence: 0.0, markers: nil, medications: nil, sections: nil)
        }
        do {
            return try JSONDecoder().decode(SomaExtractionResponse.self, from: data)
        } catch {
            print("[SomaAI] extract decode failed for type \(type.rawValue): \(error.localizedDescription)")
            return SomaExtractionResponse(type: type.rawValue, date: nil, organization: nil, title: nil, confidence: 0.0, markers: nil, medications: nil, sections: nil)
        }
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

Tie-breaker: if BOTH lab values AND clinical notes (diagnosis, recommendations) are present, prefer the type that dominates by character count.

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
  - If the OCR is too short or has no drug names, return "medications": [] and confidence=0.2.
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

Rules:
  - Include a section ONLY if there is actual text for it. Skip empty ones.
  - If a section name contains line breaks or newlines, collapse them into spaces.
  - If the OCR is too short, return "sections": [] and confidence=0.2.
  - 'order' is the reading order: 0, 1, 2, ...
  - Scan the WHOLE text.
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
