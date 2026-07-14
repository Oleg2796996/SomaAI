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
        ("(?:Объективный\\s+статус|Objective\\s+status)[:\\s-]+", "Объективный статус"),
        ("(?:Status\\s+localis|Status\\s+localis)[:\\s-]+", "Status localis"),
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
        // Dedup helper: two patterns can map to the same key (e.g. "Диагноз"
        // and "Диагноз клинический" both produce "Диагноз"). We pick ONE
        // hit per key — the FIRST occurrence in text order across all
        // patterns. This keeps ForEach keys unique downstream.
        // Also: if the same word appears twice in the text, we still only
        // emit one section (the first hit) — duplicate sections would
        // duplicate the same clinical info anyway.
        var seenKeys: Set<String> = []
        var hits: [(range: NSRange, key: String, headerEnd: Int)] = []
        // Collect all candidates first, then take one per key in text order.
        var candidates: [(range: NSRange, key: String, headerEnd: Int, patternIdx: Int)] = []
        for (i, pat) in patterns.enumerated() {
            guard let re = try? NSRegularExpression(pattern: pat.regex, options: [.caseInsensitive]) else { continue }
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
            for m in matches where m.range.location != NSNotFound {
                candidates.append((m.range, pat.key, m.range.location + m.range.length, i))
            }
        }
        if candidates.isEmpty { return [] }
        candidates.sort {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            // For ties, prefer the more specific pattern (later in the list
            // is more specific, e.g. "Диагноз клинический" after "Диагноз").
            return $0.patternIdx > $1.patternIdx
        }
        for c in candidates {
            if seenKeys.contains(c.key) { continue }
            seenKeys.insert(c.key)
            hits.append((c.range, c.key, c.headerEnd))
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
    /// Sprint 4.9b: filters out OCR/field-label noise that should never
    /// be treated as a marker (card numbers, page footers, "Стр. N", etc.).
    static func extractLabMarkers(_ text: String) -> [SomaMarker] {
        var markers: [SomaMarker] = []
        let lines = text.components(separatedBy: .newlines)
        // Sprint 4.9b: blacklist of OCR/field-label prefixes that look like
        // markers but are just page metadata.
        // Sprint 4.9e: expanded — capture the long tail of OCR noise from
        // scanned PDFs (table headings, truncated lines, headers).
        let noisePrefixes: [String] = [
            "№ ", "Nº", "№", "N°",  // card numbers
            "Стр.", "стр.", "Page",  // page footers
            "--- ",  // OCR debug headers
            "Биоматериал:", "Заказчик:", "Отделение", "Врач:", "Адрес:",
            "Дата рождения:", "Пол:", "Ф.И.О.:", "Доставка", "Результат клинического",
            // Sprint 4.9e additions:
            "Анализ", "Анализы", "Исследовани", "Исследование",  // table headers
            "Показатель", "Метод", "Единицы", "Референс",  // column headers
            "Подпис", "Дата выполнения", "Время", "Sample",  // footer/metadata
            "Test", "Lab",  // generic EN headers
        ]
        // Sprint 4.9e: lines whose 'name' part is too short (≤3 chars) or
        // matches a generic word are almost certainly OCR artefacts, not
        // real marker names like "Эритроциты, RBC" (≥7 chars typically).
        let genericNames: Set<String> = [
            "Анализ", "Анализы", "Исследование", "Test", "Lab", "Биоматериал",
            "Стр.", "Page", "Sample", "Метод", "Результат",
        ]
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasSuffix(":") { continue }       // header
            if trimmed.allSatisfy({ "0123456789.,-+()/- ".contains($0) }) { continue } // pure numeric
            // Sprint 4.9b: skip noise prefixes
            if noisePrefixes.contains(where: { trimmed.hasPrefix($0) }) { continue }
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
            // Sprint 4.9b: skip if name itself is a noise word
            if noisePrefixes.contains(where: { name.hasPrefix($0) }) { continue }
            // Sprint 4.9e: skip if name is just a generic single word
            // (e.g. "Анализы", "Исследование" — these are column headers,
            // not real marker names like "Эритроциты, RBC").
            if genericNames.contains(name) { continue }
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

    /// Prefer the FIRST date in the document (sample/admission date).
    /// The LAST date is usually the "print" or "approval" date (often
    /// today), which is NOT what we want. Supports DD.MM.YYYY,
    /// DD/MM/YYYY, DD.MM.YY, "17 января 2025", ISO.
    /// Sprint 4.7ao-pdf-5e: also filter out "today" / "yesterday"
    /// dates — for medical PDFs the footer "Печать: 14.07.2026 09:53"
    /// is the print timestamp, not the sample date. If the FIRST
    /// matched date is today/yesterday, fall back to the LAST
    /// non-recent date. This handles both cases:
    ///   1. Header date "07.11.2025" is the FIRST and we want it.
    ///   2. Footer "14.07.2026 09:53" is FIRST and we want to skip
    ///      it and use the body's "07.11.2025" instead.
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
        // Sprint 4.7ao-pdf-5e: collect ALL matches in document order
        // (was: only the last one). The "last date wins" logic was
        // a bug for medical PDFs where the LAST date is the print
        // timestamp (often today), not the sample date.
        var allMatches: [(year: Int, month: Int, day: Int, position: Int)] = []
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = re.matches(in: text, options: [], range: NSRange(location: 0, length: (text as NSString).length))
            for m in matches {
                let nsText = text as NSString
                let captured = nsText.substring(with: m.range)
                if let ymd = parseDate(captured, monthMap: monthMap) {
                    allMatches.append((ymd.year, ymd.month, ymd.day, m.range.location))
                }
            }
        }
        guard !allMatches.isEmpty else { return nil }

        // Sprint 4.7ao-pdf-5e: "today/yesterday" filter. If a date is
        // within 2 days of now, it's almost certainly a print
        // timestamp, not a medical event date.
        let calendar = Calendar.current
        let now = Date()
        let twoDaysAgo = calendar.date(byAdding: .day, value: -2, to: now) ?? now
        let twoDaysAhead = calendar.date(byAdding: .day, value: 2, to: now) ?? now
        // Sprint 4.7ao-pdf-5e-bis: accept the full allMatches tuple
        // (year, month, day, position). We only use the date fields
        // for the comparison; position is carried along for callers
        // that need to know WHERE in the text the chosen date came
        // from (for the diagnostic log).
        func isRecent(_ ymd: (year: Int, month: Int, day: Int, position: Int)) -> Bool {
            var comps = DateComponents()
            comps.year = ymd.year; comps.month = ymd.month; comps.day = ymd.day
            guard let d = calendar.date(from: comps) else { return false }
            return d >= twoDaysAgo && d <= twoDaysAhead
        }

        // Strategy 0 (Sprint 4.7ao-pdf-5e-ter): keyword boost. If
        // the text contains phrases like "Дата забора",
        // "Sample collected", "Дата взятия" — find the date
        // that's CLOSEST (in text position) to that phrase.
        // This works even when the phrase sits in the middle of
        // the document and the FIRST date in document order is
        // the print/approval timestamp at the bottom.
        // Sprint 4.7ao-pdf-5e-quarter: added "доставка биоматериала",
        // "биоматериал", "время забора" — these are the actual
        // phrases on НКЦ2 lab PDFs. The 16:28 photo Oleg sent
        // shows the patient block layout:
        //   Ф.И.О.: КОНОВАЛОВ ОЛЕГ АЛЕКСАНДРОВИЧ
        //   Дата рождения: 17.01.1981 (44 г.)   Пол: М
        //   № карты: 21847522
        //   Биоматериал: Моча (разовая);
        //   Доставка биоматериала: 07.11.2025 10:59
        // The date is preceded by "Доставка биоматериала:" —
        // we need this phrase in our keyword list to activate
        // Strategy 0 (keyword proximity). Without it, 5e-ter
        // falls through to "first non-recent date" which is
        // often the print timestamp at the bottom.
        let keywords = ["дата забора", "дата взятия", "дата сдачи", "sample collected", "sample date", "collection date", "сдача анализа", "забор крови", "доставка биоматериала", "доставка:", "биоматериал:", "время забора", "дата доставки"]
        let lower = text.lowercased() as NSString
        var bestKeywordDate: (year: Int, month: Int, day: Int, position: Int)?
        for kw in keywords {
            let kwRange = lower.range(of: kw, options: [])
            guard kwRange.location != NSNotFound else { continue }
            // Find the date CLOSEST to this keyword's position.
            // Distance = abs(date.position - keyword.location).
            // If tied, pick the one with smaller position (earlier
            // in the text — dates BEFORE the keyword are usually
            // the actual date, not the print time AFTER it).
            let candidate = allMatches.min(by: { lhs, rhs in
                let dl = abs(lhs.position - kwRange.location)
                let dr = abs(rhs.position - kwRange.location)
                if dl != dr { return dl < dr }
                return lhs.position < rhs.position
            })
            if let c = candidate {
                // Only accept if within 200 chars of the keyword
                // — if no date is near, ignore.
                let dist = abs(c.position - kwRange.location)
                if dist <= 200 {
                    bestKeywordDate = c
                    break
                }
            }
        }

        // Strategy 1: FIRST non-recent date in document order.
        // Strategy 2: If all dates are recent, fall back to the FIRST
        // one (don't return today — caller already has it).
        // Strategy 3: If the FIRST date is recent but a later one is
        // not, pick the FIRST non-recent one.
        let nonRecent = allMatches.filter { !isRecent($0) }
        let chosen: (year: Int, month: Int, day: Int, position: Int)?
        if let kw = bestKeywordDate {
            // Sprint 4.7ao-pdf-5e-ter: keyword boost wins over
            // positional/recency heuristics when the keyword is
            // present. The phrase 'дата забора' is an unambiguous
            // signal that the date nearby is the sample date.
            chosen = kw
        } else if let firstNonRecent = nonRecent.first {
            chosen = firstNonRecent
        } else {
            // All dates are recent. Pick the EARLIEST one (most likely
            // the sample date even if it's a week-old document).
            chosen = allMatches.min(by: { lhs, rhs in
                lhs.year * 10000 + lhs.month * 100 + lhs.day < rhs.year * 10000 + rhs.month * 100 + rhs.day
            })
        }
        // Sprint 4.7ao-pdf-5e: log what we found so the date-fix
        // sprint can be evaluated against real OCR content.
        let allDatesStr = allMatches.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) }.joined(separator: ", ")
        let strategy = bestKeywordDate != nil ? "keyword" : (nonRecent.first != nil ? "first-non-recent" : "earliest")
        print("[SomaAI] extractBestDate: found \(allMatches.count) date(s) — [\(allDatesStr)]; recent=\(allMatches.filter(isRecent).count); strategy=\(strategy); chose=\(chosen.map { String(format: "%04d-%02d-%02d", $0.year, $0.month, $0.day) } ?? "nil")")
        guard let ymd = chosen else { return nil }
        return String(format: "%04d-%02d-%02d", ymd.year, ymd.month, ymd.day)
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
    /// Sprint 4.8: filters out OCR page-leak headers (`--- Page N ---`)
    /// that OCRPipeline injects for debugging.
    /// Sprint 4.9b: also filters PDF/V/Image OCR artefacts that appear
    /// when the source is a scanned PDF (first lines are noise).
    static func extractTitle(_ text: String, type: DocumentType, date: String?) -> String? {
        let keywords: [String] = {
            switch type {
            case .labResult: return ["Анализ", "Исследование", "Test", "Lab",
                                    "Результат клинического", "Клинико-диагностическая"]
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
        // OCR page-leak pattern: `--- Page N ---` injected by OCRPipeline.
        // Sprint 4.9b: also blacklist PDF/V/Image — these are OCR artefacts
        // when scanning a multi-page PDF (Vision adds them as noise lines).
        let pageHeaderPattern = "^--- Page \\d+ ---$"
        let ocrNoise: Set<String> = ["PDF", "V", "Image", "Page", "Scan"]
        let firstLines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .filter { line in
                line.range(of: pageHeaderPattern, options: [.regularExpression, .caseInsensitive]) == nil
                    && !line.hasPrefix("---")
                    && !line.hasSuffix("---")
                    && !ocrNoise.contains(line)
                    && line.count >= 3  // Skip single-char noise
            }
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
