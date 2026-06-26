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
    func structureText(_ text: String) async throws -> [SomaMarker] {
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

        let messages: [[String: String]] = [
            ["role": "system", "content": SomaPrompts.labMarkerExtractor],
            ["role": "user", "content": text]
        ]
        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": messages,
            "temperature": 0.1
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
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw SomaAPIError.unparseableResponse
        }

        let decoded = try JSONDecoder().decode(SomaBrainResponse.self, from: contentData)
        return decoded.markers
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
}
