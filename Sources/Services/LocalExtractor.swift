import Foundation

/// Local regex-based extraction fallback. Used when the Wormsoft LLM
/// endpoint is unreachable or times out. Quality is lower than the
/// LLM (conf 0.4) but the user can still see structured sections
/// instead of a raw text blob, and the document is never lost.
///
/// Strategy (chosen after comparing senior-developer and ML expert reviews):
///   - epicrisis/dischargeSummary/consultation: greedy header detection,
///     each header starts a new section that runs until the next header.
///   - labResult: per-row tab-separated parser.
///   - prescription: drug + dose row parser.
///   - referral/imaging/vaccination: header detection with type-specific
///     keyword sets.
///   - unknown: split into paragraphs at blank lines.
/// Date/title/org are extracted once and reused across all sections.
struct LocalExtractor {

    static func extract(_ text: String, type: DocumentType) -> SomaExtractionResponse {
        let date = extractBestDate(text)
        let org = extractOrganization(text)
        let title = extractTitle(text, type: type, date: date)

        var markers: [SomaMarker]? = nil
        var medications: [SomaMedication]? = nil
        var sections: [SomaSection]? = nil
        var confidence = 0.4

        switch type {
        case .labResult:
            markers = extractLabMarkers(text)
            confidence = (markers?.isEmpty == false) ? 0.7 : 0.2
        case .epicrisis, .dischargeSummary, .consultation:
            sections = extractClinicalSections(text)
            confidence = (sections?.isEmpty == false) ? 0.7 : 0.2
        case .prescription:
            medications = extractMedications(text)
            confidence = (medications?.isEmpty == false) ? 0.7 : 0.2
        case .referral:
            sections = extractHeaderSections(text, patterns: referralPatterns, type: type)
            confidence = (sections?.isEmpty == false) ? 0.6 : 0.2
        case .imagingReport:
            sections = extractHeaderSections(text, patterns: imagingPatterns, type: type)
            confidence = (sections?.isEmpty == false) ? 0.6 : 0.2
        case .vaccination:
            sections = extractHeaderSections(text, patterns: vaccinationPatterns, type: type)
            confidence = (sections?.isEmpty == false) ? 0.6 : 0.2
        case .unknown:
            sections = splitIntoParagraphs(text)
            confidence = 0.2
        }

        return SomaExtractionResponse(
            type: type.rawValue,
            date: date,
            organization: org,
            title: title,
            confidence: confidence,
            markers: markers,
            medications: medications,
            sections: sections
        )
    }

    // MARK: - Clinical sections (epicrisis/dischargeSummary/consultation)

    /// Greedy header parser: find the FIRST occurrence of each header
    /// pattern in the cleaned text. Each header starts a section that
    /// runs until the next header (or end of doc). Order is preserved.
    static func extractClinicalSections(_ text: String) -> [SomaSection] {
        extractHeaderSections(text, patterns: clinicalPatterns, type: nil)
    }

    static let clinicalPatterns: [(regex: String, key: String)] = [
        ("(?:Жалобы|Complaints)[:\\s-]+", "Жалобы"),
        ("(?:Анамнез(?:\\s+болезни|\\s+заболевания)?|Anamnesis(?:\\s+of\\s+present\\s+illness)?|History(?:\\s+of\\s+present\\s+illness)?)[:\\s-]+", "Анамнез"),
        ("(?:Объективный\\s+статус|Status\\s+localis|Objective\\s+status)[:\\s-]+", "Объективный статус"),
        ("(?:Status\\s+localis|Объективный\\s+статус|Objective\\s+status)[:\\s-]+", "Status localis"),
        ("(?:Особенности\\s+течения\\s+заболевания|Course\\s+of\\s+disease|Особенности\\s+течения)[:\\s-]+", "Особенности течения"),
        ("(?:Операци[яи]|Surgery|Operations?|Operative\\s+notes?)[:\\s-]+", "Операции"),
        ("(?:Лечение|Treatment|Therapy)[:\\s-]+", "Лечение"),
        ("(?:Диагноз(?:\\s+клинический|\\s+заключительный|\\s+основной)?|Diagnosis(?:\\s+clinical)?|Primary\\s+diagnosis)[:\\s-]+", "Диагноз"),
        ("(?:Сопутствующий\\s+диагноз|Comorbidit(?:y|ies))[:\\s-]+", "Сопутствующий диагноз"),
        ("(?:Рекомендации|Recommendations|Follow-?up)[:\\s-]+", "Рекомендации"),
        ("(?:Вывод|Conclusion|Summary)[:\\s-]+", "Вывод"),
        ("(?:Детали|Details)[:\\s-]+", "Детали"),
        ("(?:Лабораторные\\s+данные|Lab(?:oratory)?\\s+data|Tests?)[:\\s-]+", "Лабораторные данные"),
    ]

    static let referralPatterns: [(regex: String, key: String)] = [
        ("(?:Куда|Directed\\s+to|To|Refer\\s+to)[:\\s-]+", "Куда"),
        ("(?:Цель(?:\\s+направления)?|Reason|Purpose)[:\\s-]+", "Цель"),
        ("(?:Обследования|Required\\s+tests?|Investigations?)[:\\s-]+", "Обследования"),
        ("(?:Диагноз|Diagnosis)[:\\s-]+", "Диагноз"),
        ("(?:Врач|Physician|Doctor)[:\\s-]+", "Врач"),
    ]

    static let imagingPatterns: [(regex: String, key: String)] = [
        ("(?:Модальность|Modality|Study)[:\\s-]+", "Модальность"),
        ("(?:Область|Body\\s+region|Area|Region)[:\\s-]+", "Область"),
        ("(?:Описание|Description|Findings)[:\\s-]+", "Описание"),
        ("(?:Заключение|Conclusion|Impression)[:\\s-]+", "Заключение"),
        ("(?:Протокол|Protocol)[:\\s-]+", "Протокол"),
    ]

    static let vaccinationPatterns: [(regex: String, key: String)] = [
        ("(?:Вакцина|Препарат|Vaccine|Drug)[:\\s-]+", "Вакцина"),
        ("(?:Серия|Lot|Batch)[:\\s-]+", "Серия"),
        ("(?:Доза|Dose)[:\\s-]+", "Доза"),
        ("(?:Дата|Date)[:\\s-]+", "Дата"),
        ("(?:Реакция|Reaction|Side\\s+effect)[:\\s-]+", "Реакция"),
    ]

    /// Find headers greedily in order of appearance in text. Each header
    /// starts a section that runs until the next header (or end of doc).
    /// Empty sections are dropped. Header text itself is included in
    /// the value (truncated past the header keyword) so the user sees
    /// the original phrasing.
    static func extractHeaderSections(
        _ text: String,
        patterns: [(regex: String, key: String)],
        type: DocumentType?
    ) -> [SomaSection] {
        // Build a list of (range, key) hits across all patterns, sorted
        // by start position. We use NSRegularExpression for Cyrillic support.
        var hits: [(range: NSRange, key: String, headerEnd: Int)] = []
        for (pattern, key) in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
            for m in matches where m.range.location != NSNotFound {
                hits.append((m.range, key, m.range.location + m.range.length))
            }
        }
        if hits.isEmpty { return [] }
        hits.sort { $0.range.location < $1.range.location }

        var sections: [SomaSection] = []
        let nsText = text as NSString
        for (i, hit) in hits.enumerated() {
            let start = hit.headerEnd
            let end = (i + 1 < hits.count) ? hits[i + 1].range.location : nsText.length
            guard start < end else { continue }
            let value = nsText.substring(with: NSRange(location: start, length: end - start))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Trim any leading ":" or "-" or whitespace that the regex left in.
            let cleaned = value.replacingOccurrences(of: #"^[:\-\s]+"#, with: "", options: .regularExpression)
            if !cleaned.isEmpty {
                sections.append(SomaSection(key: hit.key, value: String(cleaned.prefix(800)), order: sections.count))
            }
        }
        return sections
    }

    // MARK: - Lab markers

    /// Walk the text line-by-line. For each line that has at least 3
    /// whitespace-separated tokens and contains a numeric value, build a
    /// SomaMarker. Skip lines that look like headers (end with ":") or
    /// are pure digits.
    static func extractLabMarkers(_ text: String) -> [SomaMarker] {
        var markers: [SomaMarker] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix(":") { continue }       // header
            if trimmed.allSatisfy({ "0123456789.,-+()/- ".contains($0) }) { continue } // pure numeric
            // Split by 2+ spaces or tab (medical tables are usually aligned).
            let tokens = trimmed.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }
            if tokens.count < 2 { continue }
            // Find first numeric token (value).
            guard let valueIdx = tokens.firstIndex(where: { token in
                let cleaned = token.replacingOccurrences(of: ",", with: ".")
                return Double(cleaned) != nil
            }) else { continue }
            let name = tokens[0..<valueIdx].joined(separator: " ")
            let value = tokens[valueIdx]
            let unit: String? = (valueIdx + 1 < tokens.count) ? tokens[valueIdx + 1] : nil
            let range: String? = tokens.last.flatMap { $0 == value || $0 == unit ? nil : $0 }
            // Skip if name is too short (likely a unit symbol).
            if name.count < 2 { continue }
            // Range often looks like "120-160" or "0.8-1.2".
            markers.append(SomaMarker(
                name: String(name.prefix(50)),
                value: value,
                unit: unit,
                referenceRange: range,
                flag: nil
            ))
        }
        return markers
    }

    // MARK: - Medications

    /// Extract drugs from "DrugName по 500mg 2 раза в день" or
    /// "Rp. DrugName 500mg" or numbered "1. DrugName 500mg".
    static func extractMedications(_ text: String) -> [SomaMedication] {
        var meds: [SomaMedication] = []
        let lines = text.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Pattern: "DrugName по 500mg..."
            let doseMatch = trimmed.range(of: #"^(.{2,40}?)\s+по\s+(\d+(?:\.\d+)?\s*(?:мг|mg|мл|ml|таб|tab|кап|drops?))\b"#, options: [.regularExpression])
            if let m = doseMatch,
               let doseRange = trimmed[m].range(of: #"\d+(?:\.\d+)?\s*(?:мг|mg|мл|ml|таб|tab|кап|drops?)\b"#, options: .regularExpression) {
                let name = String(trimmed[m].prefix(upTo: trimmed[m].range(of: " по ")?.lowerBound ?? trimmed[m].endIndex)).trimmingCharacters(in: .whitespaces)
                let dose = String(trimmed[doseRange])
                meds.append(SomaMedication(name: name, dose: dose, frequency: nil, duration: nil))
                continue
            }
            // Pattern: "Rp. DrugName 500mg"
            if let rpMatch = trimmed.range(of: #"^Rp\.\s+(.{2,60}?)\s+(\d+(?:\.\d+)?\s*(?:мг|mg|мл|ml|таб|tab|кап|drops?))"#, options: [.regularExpression]) {
                let captured = String(trimmed[rpMatch])
                let parts = captured.components(separatedBy: .whitespaces)
                if parts.count >= 3 {
                    meds.append(SomaMedication(name: parts.dropFirst().dropLast().joined(separator: " "), dose: parts.last ?? "", frequency: nil, duration: nil))
                }
                continue
            }
        }
        return meds
    }

    // MARK: - Paragraph splitter for unknown

    static func splitIntoParagraphs(_ text: String) -> [SomaSection] {
        let paragraphs = text.replacingOccurrences(of: #"\n\s*\n"#, with: "<<PARA>>", options: .regularExpression)
            .components(separatedBy: "<<PARA>>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 10 }
        return paragraphs.enumerated().map { (i, p) in
            SomaSection(key: "Часть \(i + 1)", value: String(p.prefix(800)), order: i)
        }
    }

    // MARK: - Date extraction

    /// Prefer the LAST date in the document (discharge > admission > lab).
    /// Supports DD.MM.YYYY, DD/MM/YYYY, DD.MM.YY, "17 января 2025", ISO.
    static func extractBestDate(_ text: String) -> String? {
        let patterns: [String] = [
            #"\b(\d{1,2})[./](\d{1,2})[./](\d{4})\b"#,
            #"\b(\d{1,2})[./](\d{1,2})[./](\d{2})\b"#,
            #"\b(\d{4})-(\d{2})-(\d{2})\b"#,
            #"\b(\d{1,2})\s+(января|февраля|марта|апреля|мая|июня|июля|августа|сентября|октября|ноября|декабря)\s+(\d{4})\b"#,
        ]
        let monthMap: [String: String] = [
            "января": "01", "февраля": "02", "марта": "03", "апреля": "04",
            "мая": "05", "июня": "06", "июля": "07", "августа": "08",
            "сентября": "09", "октября": "10", "ноября": "11", "декабря": "12"
        ]
        var lastMatch: (year: Int, month: Int, day: Int)? = nil
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
            for m in matches {
                let nsText = text as NSString
                let captured = nsText.substring(with: m.range)
                let ymd = parseDate(captured, monthMap: monthMap)
                if let ymd = ymd {
                    if let prev = lastMatch {
                        if ymd.year * 10000 + ymd.month * 100 + ymd.day >= prev.year * 10000 + prev.month * 100 + prev.day {
                            lastMatch = ymd
                        }
                    } else {
                        lastMatch = ymd
                    }
                }
            }
        }
        if let ymd = lastMatch {
            return String(format: "%04d-%02d-%02d", ymd.year, ymd.month, ymd.day)
        }
        return nil
    }

    private static func parseDate(_ raw: String, monthMap: [String: String]) -> (year: Int, month: Int, day: Int)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // ISO
        if let isoRange = trimmed.range(of: #"^(\d{4})-(\d{2})-(\d{2})$"#, options: .regularExpression) {
            let parts = String(trimmed[isoRange]).split(separator: "-").compactMap { Int($0) }
            if parts.count == 3 { return (parts[0], parts[1], parts[2]) }
        }
        // Russian "17 января 2025"
        let lower = trimmed.lowercased()
        for (name, num) in monthMap {
            if lower.contains(name) {
                let parts = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
                if parts.count >= 3,
                   let day = Int(parts[0]),
                   let year = Int(parts[2]) {
                    return (year, Int(num) ?? 1, day)
                }
            }
        }
        // DD.MM.YYYY or DD/MM/YYYY
        let numericParts = trimmed.components(separatedBy: CharacterSet(charactersIn: "./- "))
            .filter { !$0.isEmpty }
        if numericParts.count == 3,
           let d = Int(numericParts[0]),
           let m = Int(numericParts[1]) {
            var y = Int(numericParts[2]) ?? 0
            if y < 100 { y += 2000 }
            return (y, m, d)
        }
        return nil
    }

    // MARK: - Title extraction

    /// First non-empty line that matches a document-type keyword,
    /// optionally combined with the first date.
    static func extractTitle(_ text: String, type: DocumentType, date: String?) -> String? {
        let keywords: [String] = {
            switch type {
            case .labResult: return ["Анализ", "Исследование", "Test", "Lab"]
            case .epicrisis: return ["Эпикриз", "Epicrisis"]
            case .dischargeSummary: return ["Эпикриз выписной", "Выписка", "Discharge"]
            case .prescription: return ["Рецепт", "Назначение", "Prescription"]
            case .referral: return ["Направление", "Referral"]
            case .consultation: return ["Консультация", "Заключение", "Consultation"]
            case .imagingReport: return ["Протокол", "Заключение", "Imaging", "Radiology"]
            case .vaccination: return ["Вакцинация", "Прививка", "Vaccination"]
            case .unknown: return []
            }
        }()
        let firstLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(10)
        for line in firstLines {
            for kw in keywords {
                if line.range(of: kw, options: [.caseInsensitive]) != nil {
                    if let date = date {
                        return "\(line.prefix(80)) (\(date))"
                    }
                    return String(line.prefix(80))
                }
            }
        }
        return firstLines.first.map { String($0.prefix(80)) }
    }

    // MARK: - Organization extraction

    /// Look for org keywords and grab the containing line + next 2 lines.
    static func extractOrganization(_ text: String) -> String? {
        let keywords = [
            "ГКБ", "Городская клиническая больница", "Больница",
            "Клиника", "Медицинский центр", "Медицинская клиника",
            "Национальный медицинский", "Научно-клинический", "Научный центр",
            "Госпиталь", "Поликлиника",
            "Hospital", "Clinic", "Medical Center", "Medical Centre",
            "University Hospital", "Health", "Surgery Center",
        ]
        let lines = text.components(separatedBy: .newlines)
        for (i, line) in lines.enumerated() {
            for kw in keywords {
                if line.range(of: kw, options: [.caseInsensitive]) != nil {
                    let cap = i + 2 < lines.count ? i + 2 : lines.count - 1
                    let combined = lines[i...min(cap, lines.count - 1)]
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    // Trim address/phone suffixes.
                    let cleaned = combined.replacingOccurrences(of: #"[,;]?\s*(тел\.?|телефон|phone|address|адрес).*$"#, with: "", options: [.regularExpression, .caseInsensitive])
                    return String(cleaned.prefix(200)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }
}
