// Sprint 4.7ao-pdf-5d-eleventh: extract markers DIRECTLY from
// PDFKit native text (PDFDocument.string), bypassing Vision OCR
// entirely for digital PDFs.
//
// CONTEXT: at 16:58 Oleg ran 5d-tenth (e500c6a) and got:
//   - Date 2025-11-07 from PDFKit string ✅
//   - markers=0, sections=11 ❌  (75s timeout hit before LLM call
//     finished because 4 Vision OCR calls × ~20s = 80s > 75s)
//
// At 17:55 Oleg ran 4a2a615 (5d-eleventh-ter) and got:
//   - Date 2025-11-07 from PDFKit string ✅
//   - "[SomaAI] PDF native parse yielded < 5 markers or no parse"
//   - Vision OCR fallback ran and gave 1020 chars / 0.59 conf
//   - 75s timeout hit AGAIN
//
// ROOT CAUSE: My first PDFNativeParser.parseTable relied on a
// 4-non-empty-lines-per-row layout. But the НКЦ2 PDF has
// VARIABLE row layouts in pdf.string (from pymupdf's
// get_text("text") on the same file, which is how iOS PDFKit
// emits):
//
//   "     Цвет\nсоломенно -\nжелтый\nсоломенно -\nжелтый\n
//    Прозрачность\nпрозрачная\nпрозрачная\n
//    Относительная плотность\n1,027\n1,008 - 1,025\nг/мл\nповышено\n
//    Реакция\n6\n5 - 7,5\n
//    Белок\n0\n0 - 0,1\nг/л\n..."
//
// "Цвет" has 4 non-empty lines (split value + split range).
// "Прозрачность" has 2 non-empty lines (one value + one range).
// "Относительная плотность" has 4 non-empty lines (value + range +
//   unit + comment).
// "Реакция" has 2 non-empty lines (value + range, no unit/comment).
// "Белок" has 3 non-empty lines (value + range + unit).
//
// There is no fixed column count per row. We need a different
// strategy.
//
// NEW STRATEGY (5d-twelfth):
//   1. Find the table by locating the column header
//      ("Показатель" + "Результат" + "Норма" + "Единицы").
//   2. For each marker name (a line with a Cyrillic/Russian
//      string that's not a section header or footer), take
//      everything until the NEXT marker name or section
//      boundary, and parse that block.
//
//   How do we recognise a "marker name" line? Heuristic:
//   - A line is a marker name if it has NO leading numeric
//     content (no digit-starting token) AND it's not in a
//     known-stop list ("Стр. 1 из 2", "Анализы выполнены", etc.).
//   - Values: pure digits, decimals, "не обнаружено",
//     "отсутствуют", "отрицательно", "единичные", or ranges
//     like "1,008 - 1,025".
//   - Units: short strings containing "/", "мкл", "мг",
//     "ммоль", "мкмоль", "ед." or "в поле зр"/"в препарате".
//   - Comments: anything else that doesn't match.
//
//   We also extract: the patient block at the top
//   (Ф.И.О., Дата рождения, № карты, Биоматериал, Врач, Лаб)
//   and use a regex to capture the lab name from the first
//   clinic header.

import Foundation
import PDFKit

enum PDFNativeParser {

    /// Result of a native PDF text parse.
    struct PDFMarker: Equatable {
        let name: String
        let value: String?
        let unit: String?
        let referenceRange: String?
        let comment: String?
    }

    struct PDFPatientInfo {
        let fullName: String?
        let birthDate: String?
        let cardNumber: String?
        let biomaterial: String?
        let laboratory: String?
        let doctorName: String?
    }

    struct PDFParseResult {
        let markers: [PDFMarker]
        let patient: PDFPatientInfo
    }

    /// 5d-scan-regex-first: parse markers directly from a pre-cleaned
    /// OCR text. Used by the scan pipeline to skip the LLM extraction
    /// step when the text has the same lab-table structure as our PDF
    /// parser. Falls back to LLM only if < 5 markers are recovered.
    ///
    /// Returns the same PDFParseResult as `parse(pdf:)` so the rest
    /// of the pipeline (processAndVerify, LabTestDetailView) works
    /// without any code changes.
    static func parse(text ocrText: String) -> PDFParseResult? {
        let cleaned = ocrText.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        guard cleaned.count > 200 else { return nil }
        let physchem = parseTable(in: cleaned, sectionHeader: "Физико-химические свойства")
        let micro    = parseTable(in: cleaned, sectionHeader: "Микроскопическое исследование осадка")
        var all: [PDFMarker] = []
        all.append(contentsOf: physchem)
        all.append(contentsOf: micro)
        // De-dup by name+value (line-aware parser can double-emit on
        // certain OCR-merged rows).
        var seen: Set<String> = []
        all = all.filter { m in
            let k = (m.name.lowercased()) + "|" + (m.value ?? "").lowercased()
            return seen.insert(k).inserted
        }
        // 5d-scan-regex-first-fix: drop markers with no value AND no
        // range (footer/header leaks that started with a capital
        // Cyrillic letter and slipped past isMarkerName).
        all = all.filter { m in
            let hasValue = !(m.value?.isEmpty ?? true)
            let hasRange = !(m.range?.isEmpty ?? true)
            let hasName  = !m.name.isEmpty
            return hasName && (hasValue || hasRange)
        }
        if all.count < 5 {
            print("[SomaAI] PDFNativeParser(text): only \(all.count) markers (need >=5) — falling back to LLM")
            return nil
        }
        print("[SomaAI] PDFNativeParser(text): recovered \(all.count) markers (physchem=\(physchem.count) micro=\(micro.count))")
    }

    static func parse(pdf: PDFDocument) -> PDFParseResult? {
        // iOS PDFKit may use \r, \n, or \r\n as line separators.
        // Normalise to \n first.
        let raw = pdf.string
        guard let raw, raw.count > 200 else {

            print("[SomaAI] PDFNativeParser: text too short or nil (\(raw?.count ?? 0) chars)")
            return nil
        }
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
                        .replacingOccurrences(of: "\r", with: "\n")
        let first200 = String(text.prefix(200))
        print("[SomaAI] PDFNativeParser: text length=\(text.count) chars; first 200: \(first200)")
        let patient = parsePatient(text: text)

        // 5d-fifteenth: COORD-BASED parser using PDFSelections.
        // PDFKit's pdf.string already has correct text, but the
        // text merges markers/values/ranges into one line without
        // clear column boundaries. The OLD line-based parser
        // treated everything on the same line as one "name" and
        // everything on subsequent lines as continuations, which
        // merged multiple rows.
        //
        // Real example (НКЦ2 моча):
        //   line[3]: 'Цвет соломенно -'    (name + value wrapped)
        //   line[4]: 'желтый'              (continuation)
        //   line[5]: 'соломенно -'         (next row's name + value)
        //   line[6]: 'желтый'              (continuation)
        //
        // With X-coords, both rows get split into [Цвет, соломенно-желтый,
        // соломенно-желтый] and [Белок, 0, 0 - 0,1, г/л] correctly.
        let nPages = pdf.pageCount
        let pageRange = 0..<nPages
        let m1c = parseTableByCoords(in: pdf, pageRange: pageRange,
                                      sectionHeader: "Физико-химические свойства",
                                      debugName: "physchem")
        let m2c = parseTableByCoords(in: pdf, pageRange: pageRange,
                                      sectionHeader: "Микроскопическое исследование осадка",
                                      debugName: "micro")
        print("[SomaAI] PDFNativeParser(coord): Физико-химические = \(m1c.count) markers")
        for (i, m) in m1c.enumerated() {
            print("[SomaAI]   physchem[\(i)]: name='\(m.name ?? "")' value='\(m.value ?? "")' range='\(m.referenceRange ?? "")' unit='\(m.unit ?? "")' comment='\(m.comment ?? "")'")
        }
        print("[SomaAI] PDFNativeParser(coord): Микроскопическое = \(m2c.count) markers")
        for (i, m) in m2c.enumerated() {
            print("[SomaAI]   micro[\(i)]: name='\(m.name ?? "")' value='\(m.value ?? "")' range='\(m.referenceRange ?? "")' unit='\(m.unit ?? "")' comment='\(m.comment ?? "")'")
        }
        // Use coord-based result if it's at least as good as the
        // line-based one. If coord-based is much worse (e.g. 0),
        // fall back to line-based.
        var markers: [PDFMarker] = []
        let coordTotal = m1c.count + m2c.count
        let m1 = parseTable(in: text, sectionHeader: "Физико-химические свойства")
        let m2 = parseTable(in: text, sectionHeader: "Микроскопическое исследование осадка")
        let lineTotal = m1.count + m2.count
        if coordTotal >= lineTotal {
            print("[SomaAI] PDFNativeParser: using COORD-based result (\(coordTotal) markers)")
            markers.append(contentsOf: m1c)
            markers.append(contentsOf: m2c)
        } else {
            print("[SomaAI] PDFNativeParser: using LINE-based result (\(lineTotal) markers)")
            markers.append(contentsOf: m1)
            markers.append(contentsOf: m2)
        }
        print("[SomaAI] PDFNativeParser: Физико-химические = \(m1.count) markers")
        print("[SomaAI] PDFNativeParser: Микроскопическое = \(m2.count) markers")
        print("[SomaAI] PDFNativeParser: total = \(markers.count) markers")
        for (idx, m) in markers.prefix(3).enumerated() {
            print("[SomaAI]   marker[\(idx)]: name='\(m.name)' value='\(m.value ?? "nil")' range='\(m.referenceRange ?? "nil")' unit='\(m.unit ?? "nil")'")
        }
        return PDFParseResult(markers: markers, patient: patient)
    }


    // MARK: - Line-aware parser (5d-sixteenth)

    /// iOS PDFKit public API is `pdf.string` (a single string) and
    /// `page.string` (string of one page). There is NO
    /// per-line / per-word public API on iOS — `selectionsForLine()`
    /// is macOS-only.
    ///
    /// Real PDFKit output (НКЦ2 моча, observed in logs):
    ///   'Цвет соломенно -'
    ///   'желтый'                              (continuation, lowercase)
    ///   'соломенно -'                         (next row's name+value, lowercase)
    ///   'желтый'
    ///   'Прозрачность прозрачная прозрачная'  (3 cols, single space)
    ///   'Относительная плотность 1,027 1,008 - 1,025 г/мл повышено'  (5 cols)
    ///   'Реакция 6 5 - 7,5'                   (3 cols, name + 2 values)
    ///
    /// Strategy: walk all lines. For each line, decide if it
    /// starts a NEW marker (first token is a Capitalized Name)
    /// or CONTINUES the previous one (lowercase or digit first).
    /// Within a marker line, split tokens and classify them into
    /// value / range / unit / comment by shape.
    private static func parseTableByCoords(in pdf: PDFDocument,
                                           pageRange: Range<Int>,
                                           sectionHeader: String,
                                           debugName: String) -> [PDFMarker] {
        var markers: [PDFMarker] = []
        for pageIdx in pageRange {
            guard let page = pdf.page(at: pageIdx) else { continue }
            // iOS PDFKit: page.string is the per-page text.
            let raw = page.string ?? ""
            let lines: [String] = raw
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            print("[SomaAI] coordParse[\(debugName).p\(pageIdx)]: \(lines.count) visual lines from page")
            // Find section header.
            var sectionStart: Int? = nil
            for (idx, l) in lines.enumerated() {
                if l.contains(sectionHeader) { sectionStart = idx; break }
            }
            guard let start = sectionStart else { continue }
            // Skip 1-3 column-header rows after the section header.
            var i = start + 1
            var skipped = 0
            while i < lines.count && skipped < 3 {
                let l = lines[i]
                let isColumnHeader =
                    l.contains("Показатель") ||
                    l.contains("Результат") ||
                    l == "Комментарий"
                if isColumnHeader { skipped += 1; i += 1; continue }
                break
            }
            // Walk lines. Each new line whose first token is a
            // Capitalized Name starts a new row. Lines starting
            // with a lowercase letter or digit are continuations.
            while i < lines.count {
                let l = lines[i]
                if sectionHeaders.contains(l) { break }
                if stopLines.contains(l) { break }
                if l.isEmpty || l.contains("Показатель") { i += 1; continue }
                // Section footers. 5d-scan-regex-first-fix: use
                // lowercased + contains for "оборудовани" so OCR
                // variants like "Анализы выполненн" still match.
                let lLower = l.lowercased()
                if lLower.hasPrefix("анализы выполнены") || lLower.hasPrefix("анализы выполнен") ||
                   lLower.contains("оборудовани") || lLower.hasPrefix("дата выдачи") ||
                   lLower.hasPrefix("подтвердил") || lLower.hasPrefix("метод") ||
                   lLower.hasPrefix("исследование выполнено") {
                    break
                }
                let firstTok = l.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? l
                let firstTokTrimmed = firstTok.trimmingCharacters(in: .whitespaces)
                let startsLower = firstTokTrimmed.first?.isLowercase == true
                let startsDigit = firstTokTrimmed.first?.isNumber == true
                let isNewRow =
                    firstTokTrimmed.first?.isUppercase == true &&
                    !isValue(firstTokTrimmed) &&
                    !isUnit(firstTokTrimmed) &&
                    firstTokTrimmed.count >= 3
                if !isNewRow {
                    // Continuation of previous marker.
                    if let last = markers.last, startsLower {
                        let prevVal = last.value ?? ""
                        if prevVal.hasSuffix("-") || prevVal.hasSuffix(" -") {
                            var newVal = prevVal
                            while newVal.hasSuffix(" ") { newVal.removeLast() }
                            while newVal.hasSuffix("-") { newVal.removeLast() }
                            newVal += "-" + l
                            markers[markers.count - 1] = PDFMarker(
                                name: last.name,
                                value: newVal,
                                unit: last.unit,
                                referenceRange: last.referenceRange,
                                comment: last.comment
                            )
                        } else if !prevVal.isEmpty {
                            markers[markers.count - 1] = PDFMarker(
                                name: last.name,
                                value: prevVal + " " + l,
                                unit: last.unit,
                                referenceRange: last.referenceRange,
                                comment: last.comment
                            )
                        } else {
                            markers[markers.count - 1] = PDFMarker(
                                name: last.name,
                                value: l,
                                unit: last.unit,
                                referenceRange: last.referenceRange,
                                comment: last.comment
                            )
                        }
                    } else if startsDigit, let last = markers.last, last.value == nil {
                        markers[markers.count - 1] = PDFMarker(
                            name: last.name,
                            value: l,
                            unit: last.unit,
                            referenceRange: last.referenceRange,
                            comment: last.comment
                        )
                    }
                    i += 1
                    continue
                }
                // Start a new marker. Tokenize and split into
                // name (Capitalized words) + value tokens.
                let tokens = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                guard !tokens.isEmpty else { i += 1; continue }
                var nameTokens: [String] = []
                var valueTokens: [String] = []
                var nameDone = false
                for tok in tokens {
                    if !nameDone {
                        if tok.first?.isUppercase == true && !isValue(tok) && !isUnit(tok) {
                            nameTokens.append(tok)
                        } else {
                            nameDone = true
                            valueTokens.append(tok)
                        }
                    } else {
                        valueTokens.append(tok)
                    }
                }
                var name = nameTokens.joined(separator: " ")
                if name.isEmpty { i += 1; continue }
                // 5d-seventeenth: multi-word names like
                // 'Кетоновые тела', 'Реакция на кровь', 'Клетки
                // плоского эпителия', 'Неорганиз. осадок мочи
                // (соли)', 'Лейкоцитарная эстераза',
                // 'Альбумин/Креатинин' have 2+ capitalized
                // words. The line-aware logic correctly puts both
                // in nameTokens, but ONLY when the first value
                // token is actually a value (not another name word).
                // E.g. 'Кетоновые тела 0 0 - 0,1' — 'Кетоновые' +
                // 'тела' are both capitalized, but 'тела' is
                // mis-classified as value because it has no digits.
                // We expand the name from a known alias list.
                if let expanded = expandMultiWordName(nameTokens: nameTokens, valueTokens: valueTokens) {
                    name = expanded.name
                    // valueTokens may have been shortened: the
                    // tokens absorbed into the name should be
                    // removed from valueTokens.
                    if expanded.absorbedCount > 0 {
                        valueTokens = Array(valueTokens.dropFirst(expanded.absorbedCount))
                    }
                }
                // Classify value tokens: 1st=value, 2nd=range,
                // 3rd=unit-or-comment, 4th=comment.
                var value: String? = nil
                var range: String? = nil
                var unit: String? = nil
                var comment: String? = nil
                if valueTokens.count >= 1 { value = valueTokens[0] }
                if valueTokens.count >= 2 { range = valueTokens[1] }
                if valueTokens.count >= 3 {
                    let t = valueTokens[2]
                    if isUnit(t) { unit = t }
                    else { comment = t }
                }
                if valueTokens.count >= 4 { comment = valueTokens[3] }
                // 5d-eighteenth: handle range with literal hyphen.
                // PDFKit may emit '5 - 7,5' as 3 tokens ['5', '-',
                // '7,5'] where the position of '-' varies. Find
                // the '-' in valueTokens and glue [before] + ' - '
                // + [after] into range.
                if let dashIdx = valueTokens.firstIndex(where: { $0 == "-" || $0 == "—" || $0 == "–" }),
                   dashIdx > 0, dashIdx < valueTokens.count - 1 {
                    let before = valueTokens[dashIdx - 1]
                    let after = valueTokens[dashIdx + 1]
                    if isValue(before), isValue(after) {
                        range = "\(before) - \(after)"
                        // valueTokens[..dashIdx-1] stays as value
                        // (already set), valueTokens[dashIdx+2..]
                        // become unit-or-comment.
                        let remaining = Array(valueTokens.dropFirst(dashIdx + 2))
                        if remaining.count >= 1 {
                            let t = remaining[0]
                            if isUnit(t) { unit = t }
                            else { comment = t }
                        }
                        if remaining.count >= 2 { comment = remaining[1] }
                    }
                }
                // 5d-eighteenth: de-dup value. PDFKit sometimes
                // repeats the same phrase twice ('соломенно-желтый
                // соломенно-желтый'). Also: handle 'X X' where
                // second is exact copy of first.
                if let v = value, v.count > 5 {
                    // Try splitting in half and check both halves.
                    let mid = v.index(v.startIndex, offsetBy: v.count / 2)
                    let first = String(v[..<mid]).trimmingCharacters(in: .whitespaces)
                    let second = String(v[mid...]).trimmingCharacters(in: .whitespaces)
                    if !first.isEmpty && first == second {
                        value = first
                    } else {
                        // 5d-eighteenth: 'соломенно желтый соломенно -
                        // желтый' — drop ' соломенно -' before last
                        // 'желтый' if pattern matches.
                        if v.contains(" - "),
                           let dashRange = v.range(of: " - ") {
                            let before = v[..<dashRange.lowerBound]
                            let after = v[dashRange.upperBound...]
                            // 'соломенно желтый соломенно -желтый' →
                            // before='соломенно желтый соломенно'
                            // after='желтый'. Glue 'before + after' but
                            // drop trailing 'before' word if it's a
                            // duplicate of 'after' prefix.
                            let beforeTrim = before.trimmingCharacters(in: .whitespaces)
                            if beforeTrim.hasSuffix(String(after)) {
                                value = beforeTrim + " " + after
                            } else {
                                value = String(before) + String(after)
                            }
                        }
                    }
                }
                markers.append(PDFMarker(
                    name: name,
                    value: value,
                    unit: unit,
                    referenceRange: range,
                    comment: comment
                ))
                i += 1
            }
        }
        return markers
    }

    // MARK: - Multi-word name expansion (5d-seventeenth)

    /// Known multi-word marker names. Maps the FULL name to the
    /// count of tokens that the name occupies. The parser checks
    /// each entry: if `nameTokens` starts with the prefix, expand.
    private static let multiWordNames: [String] = [
        "Кетоновые тела",
        "Реакция на кровь",
        "Клетки плоского эпителия",
        "Клетки переходного эпителия",
        "Клетки почечного эпителия",
        "Неорганиз. осадок мочи (соли)",
        "Неорганический осадок мочи",
        "Лейкоцитарная эстераза",
        "Альбумин/Креатинин",
        "Альбумин/Креатининовый индекс",
        "Относительная плотность",
        "Дрожжеподобные грибы",
    ]

    /// Try to expand a partial name. Given `nameTokens` and the
    /// full token list after the first non-name token, see if any
    /// entry in `multiWordNames` matches `nameTokens + valueTokens[..n]`.
    /// Returns the expanded name and the count of valueTokens
    /// absorbed into the name.
    private static func expandMultiWordName(
        nameTokens: [String],
        valueTokens: [String]
    ) -> (name: String, absorbedCount: Int)? {
        // For each known multi-word name, check whether its prefix
        // matches `nameTokens`. The first N tokens of the entry
        // must equal `nameTokens`. Then the remaining M tokens
        // of the entry must equal the first M tokens of
        // `valueTokens`. If so, the expanded name absorbs the
        // first M valueTokens.
        for entry in multiWordNames {
            let entryTokens = entry.split(separator: " ").map(String.init)
            guard entryTokens.count >= 2 else { continue }
            guard entryTokens.count > nameTokens.count else { continue }
            // Check that `nameTokens` matches the entry's first
            // `nameTokens.count` tokens.
            let namePrefix = Array(entryTokens.prefix(nameTokens.count))
            guard namePrefix == nameTokens else { continue }
            // The remaining entry tokens need to match valueTokens.
            let remaining = Array(entryTokens.dropFirst(nameTokens.count))
            guard remaining.count <= valueTokens.count else { continue }
            for (i, t) in remaining.enumerated() {
                if valueTokens[i] != t { return nil }
            }
            return (name: entry, absorbedCount: remaining.count)
        }
        return nil
    }
    // MARK: - Patient

    private static func parsePatient(text: String) -> PDFPatientInfo {
        func firstMatch(of pattern: String) -> String? {
            guard let range = text.range(of: pattern, options: .regularExpression) else {
                return nil
            }
            let after = text[range.upperBound...]
            if let nl = after.firstIndex(of: "\n") {
                let value = after[..<nl].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            return after.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return PDFPatientInfo(
            fullName: firstMatch(of: "Ф\\.И\\.О\\.:[ \\t]*"),
            birthDate: firstMatch(of: "Дата рождения:[ \\t]*"),
            cardNumber: firstMatch(of: "№ карты:[ \\t]*"),
            biomaterial: firstMatch(of: "Биоматериал:[ \\t]*"),
            laboratory: firstMatch(of: "Научно-клинический центр[^\\n]*"),
            doctorName: firstMatch(of: "Врач:[ \\t]*")
        )
    }

    // MARK: - Tables (5d-twelfth strategy: variable row layout)

    /// Lines that mark a non-marker-name line (footers, headers, etc.)
    private static let stopLines: Set<String> = [
        "Стр. 1 из 2", "Стр. 2 из 2",
        "Анализы выполнены на оборудовании",
        "Результат лабораторного исследования не является диагнозом",
        "Исследование выполнено из доставленного биоматериала",
    ]

    /// Is this line a known section header? We use it to break the
    /// row-block parsing.
    private static let sectionHeaders: Set<String> = [
        "Физико-химические свойства",
        "Микроскопическое исследование осадка",
        "Показатель", "Результат", "Норма",
        "Комментарий", "Единицы",
    ]

    /// Heuristic: is this line a marker NAME?
    ///
    /// 5d-fourteenth redesign: iOS PDFKit's pdf.string emits a SINGLE
    /// line that contains both the marker name AND the value, separated
    /// by 2+ spaces. Examples from НКЦ2 PDF (real logs):
    ///   'Цвет соломенно -'           (line[3])
    ///   'желтый'                     (line[4], continuation of soft-hyphen wrap)
    ///   'Прозрачность прозрачная прозрачная'  (line[7])
    ///   'Относительная плотность 1,027 1,008 - 1,025 г/мл повышено'  (line[8])
    ///
    /// Strategy: split each line by 2+ spaces. The first chunk is the
    /// candidate name. Then test that candidate against the same strict
    /// checks as before.
    private static func isMarkerName(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Reject known stop lines.
        if stopLines.contains(t) { return false }
        if sectionHeaders.contains(t) { return false }
        // Pure numerics / ranges are not names.
        if t.allSatisfy({ "0123456789,.- \t".contains($0) }) { return false }
        // Take the FIRST column as the candidate name (PDFKit uses
        // 2+ spaces as column separator).
        let columns = t.components(separatedBy: "  ")  // 2-space separator (PDFKit default)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let candidate = columns.first ?? t
        // If the candidate itself is a value or unit, this is not a
        // marker line.
        if isValue(candidate) { return false }
        if isUnit(candidate) { return false }
        // Must start with a capital letter (marker names are Capitalized;
        // value lines like 'соломенно', 'желтый', 'прозрачная' are not).
        guard let first = candidate.first, first.isUppercase else { return false }
        // Reject very short fragments (< 3 chars).
        guard candidate.count >= 3 else { return false }
        return true
    }

    /// Extract the name (first column) from a marker line. PDFKit
    /// uses 2+ spaces as column separator.
    private static func extractName(from line: String) -> String? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let columns = t.components(separatedBy: "  ")  // 2-space separator (PDFKit default)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let first = columns.first else { return nil }
        guard first.first?.isUppercase == true else { return nil }
        guard !isValue(first), !isUnit(first) else { return nil }
        guard first.count >= 3 else { return nil }
        return first
    }

    /// Is this line a unit? Matches: г/л, мг/л, ммоль/л, мкмоль/л,
    /// МКЛ, мкл, ед., в поле зр, в препарате, в поле зрения.
    private static func isUnit(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        let unitKeywords = ["/", "мкл", "мг", "ммоль", "мкмоль", "ед.", "поле зр", "препар", "мл/мин"]
        for kw in unitKeywords {
            if t.lowercased().contains(kw.lowercased()) { return true }
        }
        return false
    }

    /// Is this line a value? Numeric, "не обнаружено",
    /// "отсутствуют", "отрицательно", "единичные", "небольшое",
    /// or range "1,008 - 1,025".
    private static func isValue(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        let valueKeywords = ["не обнаружено", "отсутствуют", "отсутствует",
                             "отрицательно", "единичные", "небольшое",
                             "большое", "умеренное", "много", "мало",
                             "соломенно", "прозрачная", "мутная",
                             "желтый", "желтая"]
        for kw in valueKeywords {
            if t.lowercased().contains(kw.lowercased()) { return true }
        }
        // Numeric / range.
        if t.allSatisfy({ "0123456789,.- \t".contains($0) }) { return true }
        if let first = t.first, first.isNumber { return true }
        if t.contains(" - ") || t.contains("-") {
            // "1,008 - 1,025" pattern
            let parts = t.components(separatedBy: "-")
            if parts.count >= 2, parts.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).allSatisfy({ "0123456789,. ".contains($0) }) && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return true
            }
        }
        return false
    }

    private static func parseTable(in text: String, sectionHeader: String) -> [PDFMarker] {
        guard let headerRange = text.range(of: sectionHeader) else {
            print("[SomaAI] parseTable[\(sectionHeader)]: section header not found")
            return []
        }
        // Stop at the next section header or footer.
        let after = text[headerRange.upperBound...]

        // Find the column header (Показатель/Результат/Норма/Единицы).
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        print("[SomaAI] parseTable[\(sectionHeader)]: \(lines.count) lines after section header")
        // Print first 10 lines so we can see the column header format
        for (idx, l) in lines.prefix(10).enumerated() {
            print("[SomaAI]   line[\(idx)]: \(l.isEmpty ? "<empty>" : "'" + l + "'")")
        }

        var i = 0
        // Skip to the column header.
        var foundHeader = false
        while i + 4 < lines.count {
            if lines[i] == "Показатель"
                && lines[i + 1] == "Результат"
                && lines[i + 2] == "Норма"
                && (lines[i + 3] == "Комментарий" || lines[i + 3] == "Единицы")
                && lines[i + 4] == "Единицы" {
                foundHeader = true
                break
            }
            i += 1
        }
        if !foundHeader {
            // FALLBACK: search for Показатель/Результат/Норма/Единицы on
            // the SAME line separated by 2+ spaces. iOS PDFKit may emit
            // a single-line column header.
            for (idx, l) in lines.prefix(15).enumerated() {
                if l.contains("Показатель") && l.contains("Результат") && l.contains("Норма") && l.contains("Единицы") {
                    print("[SomaAI] parseTable[\(sectionHeader)]: INLINE column header at line \(idx)")
                    i = idx + 1
                    foundHeader = true
                    break
                }
            }
        }
        print("[SomaAI] parseTable[\(sectionHeader)]: foundHeader=\(foundHeader) i=\(i)")
        guard i + 4 < lines.count else { return [] }
        i += 5  // skip the column header

        // Now walk through lines. A "marker name" line is the start
        // of a row. The next 1-5 non-empty lines (until the next
        // marker name or section boundary) are value/range/comment/
        // unit.
        var markers: [PDFMarker] = []
        let total = lines.count

        while i < total {
            // Skip empty lines.
            while i < total, lines[i].isEmpty { i += 1 }
            guard i < total else { break }

            let raw = lines[i]
            // Stop at section boundary or footer.
            if stopLines.contains(raw) { break }
            if sectionHeaders.contains(raw) { break }

            // If this is not a marker line, just skip it.
            guard isMarkerName(raw) else {
                i += 1
                continue
            }

            // 5d-fourteenth: PDFKit often puts the value on the SAME
            // line as the name, separated by 2+ spaces. Example:
            //   'Цвет соломенно -'          → name='Цвет', inlineValue='соломенно -'
            //   'Прозрачность прозрачная прозрачная'  → name='Прозрачность', inlineValue='прозрачная', ref='прозрачная'
            //   'Относительная плотность 1,027 1,008 - 1,025 г/мл повышено'
            //        → name='Относительная плотность', value='1,027',
            //          range='1,008 - 1,025', unit='г/мл', comment='повышено'
            let name = extractName(from: raw) ?? raw
            let columns = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: "  ")  // PDFKit uses 2+ spaces as column separator
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let inlineColumns = Array(columns.dropFirst())  // everything after the name

            // Read the next non-empty lines (continuations of wrapped
            // values, or second-row columns that PDFKit may have split).
            var continuation: [String] = []
            var j = i + 1
            while j < total {
                let l = lines[j]
                if l.isEmpty { j += 1; continue }
                if stopLines.contains(l) || sectionHeaders.contains(l) { break }
                if isMarkerName(l) { break }
                continuation.append(l)
                j += 1
                if continuation.count >= 4 { break }
            }

            // Build the row from inline columns + continuations.
            // PDFKit splits long values with soft-hyphen across lines,
            // e.g. 'соломенно -' / 'желтый' should join to 'соломенно-желтый'.
            // We do that by concatenation-with-hyphen when a continuation
            // starts with a lowercase letter (it's a wrapped word).
            var allColumns: [String] = inlineColumns
            for c in continuation {
                if let last = allColumns.last,
                   last.hasSuffix(" -") || last.hasSuffix("-"),
                   c.first?.isLowercase == true {
                    // Wrap continuation: join with hyphen.
                    var joined = last
                    joined.removeLast()  // drop the trailing '-'
                    joined += c
                    allColumns[allColumns.count - 1] = joined
                } else {
                    allColumns.append(c)
                }
            }

            // Classify columns into value / range / unit / comment.
            // 1st = value, 2nd = range, 3rd = unit or comment,
            // 4th = comment.
            var value: String? = nil
            var range: String? = nil
            var unit: String? = nil
            var comment: String? = nil
            if allColumns.count >= 1 { value = allColumns[0] }
            if allColumns.count >= 2 { range = allColumns[1] }
            if allColumns.count >= 3 {
                let third = allColumns[2]
                if isUnit(third) {
                    unit = third
                } else {
                    comment = third
                }
            }
            if allColumns.count >= 4 { comment = allColumns[3] }

            // Filter out cases where the value is actually a duplicate
            // of the name (no real value). Example: when PDFKit emits
            // a row as 'Неорганиз. осадок мочи (соли) отсутствуют отсутствуют'
            // we'd get name='Неорганиз. осадок мочи (соли)',
            // value='отсутствуют', range='отсутствуют' — which is fine.
            // But sometimes the inlineValue is a continuation word
            // ('желтый' alone) that joined into nothing useful. If
            // value is a single lowercase word and there's no range,
            // and we have a 'name value' line, we should leave value
            // as-is (it was wrapped from a longer value).
            let m = PDFMarker(
                name: name,
                value: value,
                unit: unit,
                referenceRange: range,
                comment: comment
            )
            markers.append(m)
            i = j
        }

        print("[SomaAI] parseTable[\(sectionHeader)]: parsed \(markers.count) markers")
        for (idx, m) in markers.prefix(5).enumerated() {
            print("[SomaAI]   parsed[\(idx)]: name='\(m.name)' value='\(m.value ?? "nil")' range='\(m.referenceRange ?? "nil")' unit='\(m.unit ?? "nil")'")
        }
        return markers
    }

    // MARK: - parseTableV2: Vision OCR text parser (5d-twenty-eighth)
    //
    // CONTEXT: `parseTable` above assumes PDFKit-style "2+ spaces as
    // column separator" layout and a STRICT column header
    // (Показатель/Результат/Норма/Единицы on consecutive lines).
    // Vision OCR (macOS/iOS Vision framework, NSAttributedString-based
    // confidence 0.6-0.8) emits single-space-separated tokens, may
    // merge header words with first data row, and may break single
    // values across 2-3 lines.
    //
    // Real Vision OCR output (from Oleg's 5d-twenty-seventh logs at
    // 16.07.2026 17:39, confidence=0.7632):
    //   line[1]: 'Цвет Результат соломенно - Норма Единицы Комментарий'
    //   line[2]: 'желтый соломенно - желтый'
    //   line[3]: 'Прозрачность прозрачная прозрачная'
    //   line[4]: 'Относительная плотность Реакция 1,027 1,008 - 1,025 г/мл повышено'
    //   line[5]: 'Белок : 5 - 7,5 0 - 0,1'
    //   line[6]: 'Глюкоза г/л'
    //
    // `parseTable` cannot find the column header (because header
    // words are interleaved with data) → foundHeader=false → 0
    // markers recovered.
    //
    // STRATEGY (5d-twenty-eighth):
    //   1. Pre-filter: drop obvious footer/header lines BEFORE parsing.
    //   2. Whitelist-based: recognise marker names by matching against
    //      a curated set of urine-marker names (case-insensitive,
    //      tolerant of trailing punctuation). This bypasses the need
    //      to find the column header.
    //   3. Regex-based per-line extraction: for each marker-name hit,
    //      consume tokens after the name and classify them into
    //      value / range / unit / comment by shape.
    //   4. Wrap-merge: lowercase-first / digit-first lines are
    //      continuations of the previous marker's value or range.
    //   5. Section split by the two real section headers (we still
    //      need to know which section a marker belongs to, for unit
    //      inference later).

    /// 5d-twenty-eighth: known marker names for urinalysis. Matched
    /// case-insensitive prefix-substring against the line.
    /// Order matters: longer names must come first so "Кетоновые тела"
    /// matches before "Кетоновые".
    private static let urineMarkerNames: [String] = [
        // Физико-химические свойства
        "Цвет",
        "Прозрачность",
        "Относительная плотность",
        "Реакция",  // pH
        "Белок",
        "Глюкоза",
        "Кетоновые тела",
        "Уробилиноген",
        "Билирубин",
        "Нитриты",
        "Реакция на кровь",
        "Альбумин",
        "Альбумин/Креатинин",
        "Аскорбиновая кислота",
        // Микроскопическое исследование осадка
        "Лейкоциты",
        "Эритроциты неизмененные",
        "Эритроциты измененные",
        "Эритроциты",
        "Цилиндры гиалиновые",
        "Цилиндры зернистые",
        "Цилиндры восковидные",
        "Цилиндры",
        "Клетки плоского эпителия",
        "Клетки переходного эпителия",
        "Клетки эпителия",
        "Слизь",
        "Бактерии",
        "Дрожжеподобные грибы",
        "Дрожжеподобные",
        "Сперматозоиды",
        "Соли",
        "Неорганический осадок",
    ]

    /// 5d-twenty-eighth: lines that are clearly NOT marker data —
    /// patient info, doctor signatures, page footers, etc.
    private static let visionFooterBlacklist: [String] = [
        "Подпись", "Воробьева", "Врач", "Ф.И.О.", "Дата рождения",
        "№ карты", "Биоматериал", "Лаборатория", "Пол",
        "Стр.", "Page", "Дата выдачи", "Заявка №", "Заказчик:",
        "Исследование выполнил", "Исследование выполнено",
        "пациента", "Отделение", "Карта", "Метод:",
        "Анализы выполнены", "Анализ выполнен", "оборудовани",
        "подтвердил", "Исполнитель", "Результат лабораторного",
        "не является диагнозом", "Стр. ",
    ]

    /// True if any blacklist keyword is found at the start or as a
    /// whole word in the line.
    private static func isBlacklistedVisionLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }  // empty lines dropped here
        for kw in visionFooterBlacklist {
            if t.hasPrefix(kw) || t == kw { return true }
            // Whole-word match: keyword surrounded by spaces.
            if t.contains(" " + kw) || t.contains(kw + " ") { return true }
            // Bare prefix: "Заявка №: 6112507" → "Заявка" prefix.
            if t.hasPrefix(kw + ":") || t.hasPrefix(kw + " №") { return true }
        }
        return false
    }

    /// 5d-twenty-eighth: try to find a marker name at the start of
    /// the line. Returns (canonicalName, lengthOfMatch) if found.
    private static func matchMarkerNameAtStart(_ line: String) -> (name: String, matched: String)? {
        let t = line.trimmingCharacters(in: .whitespaces)
        for n in urineMarkerNames {
            // Try exact-prefix match (case-insensitive), then with
            // space/colon/dash boundary.
            if t.lowercased().hasPrefix(n.lowercased() + " ") ||
               t.lowercased().hasPrefix(n.lowercased() + ":") ||
               t.lowercased() == n.lowercased() {
                return (n, n)
            }
        }
        return nil
    }

    /// 5d-twenty-eighth: Vision OCR parser. Splits the cleaned OCR
    /// text into lines, drops blacklist lines, and walks the
    /// remaining lines recognising marker-name starts.
    private static func parseTableV2(in text: String, sectionHeader: String) -> [PDFMarker] {
        // 1. Section split.
        guard let sectionStartRange = text.range(of: sectionHeader) else {
            print("[SomaAI] parseTableV2[\(sectionHeader)]: section header not found")
            return []
        }
        let after = text[sectionStartRange.upperBound...]
        // Take up to the next section or end of text.
        let sectionBoundary = ["Микроскопическое исследование осадка",
                               "Физико-химические свойства"]
        var slice = String(after)
        for boundary in sectionBoundary where boundary != sectionHeader {
            if let r = slice.range(of: boundary) {
                slice = String(slice[..<r.lowerBound])
            }
        }
        // 2. Normalise whitespace and split into lines.
        let cleaned = slice
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        // 3. Drop blacklist lines.
        let before = lines.count
        lines = lines.filter { !isBlacklistedVisionLine($0) }
        let dropped = before - lines.count
        print("[SomaAI] parseTableV2[\(sectionHeader)]: \(lines.count) lines after blacklist (dropped \(dropped))")

        // 4. Walk lines. If a line starts with a known marker name,
        // begin a new marker. If it starts with lowercase or digit,
        // append it to the previous marker's value (wrap-merge).
        var markers: [PDFMarker] = []
        var i = 0
        while i < lines.count {
            let l = lines[i]

            // Check for new marker name at the start.
            if let hit = matchMarkerNameAtStart(l) {
                // Extract everything AFTER the name on the same line.
                let after = String(l.dropFirst(hit.matched.count)).trimmingCharacters(in: .whitespaces)
                // Strip leading colon/space.
                let tail = after.hasPrefix(":") ? String(after.dropFirst()).trimmingCharacters(in: .whitespaces) : after
                // Split tail into tokens. OCR usually keeps them in
                // order: value, range, unit, comment.
                let toks = tail.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                let (val, range, unit, comment) = classifyTokens(toks)
                markers.append(PDFMarker(
                    name: hit.name,
                    value: val.isEmpty ? nil : val,
                    unit: unit,
                    referenceRange: range,
                    comment: comment
                ))
                i += 1
                continue
            }

            // Not a marker line. If it starts with lowercase or digit,
            // it's a wrap-merge continuation of the previous marker's
            // value. Otherwise, skip.
            if let first = l.first, (first.isLowercase || first.isNumber),
               markers.last != nil {
                let last = markers.last!
                let prevVal = last.value ?? ""
                let joined: String
                if prevVal.isEmpty {
                    joined = l
                } else if prevVal.hasSuffix("-") {
                    var v = prevVal
                    while v.hasSuffix(" ") { v.removeLast() }
                    while v.hasSuffix("-") { v.removeLast() }
                    joined = v + l
                } else {
                    joined = prevVal + " " + l
                }
                markers[markers.count - 1] = PDFMarker(
                    name: last.name,
                    value: joined,
                    unit: last.unit,
                    referenceRange: last.referenceRange,
                    comment: last.comment
                )
                i += 1
                continue
            }
            i += 1
        }

        print("[SomaAI] parseTableV2[\(sectionHeader)]: parsed \(markers.count) markers")
        for (idx, m) in markers.prefix(5).enumerated() {
            print("[SomaAI]   v2[\(idx)]: name='\(m.name)' value='\(m.value ?? "nil")' range='\(m.referenceRange ?? "nil")' unit='\(m.unit ?? "nil")' comment='\(m.comment ?? "nil")'")
        }
        return markers
    }

    /// 5d-twenty-eighth: classify a token list into (value, range,
    /// unit, comment). Heuristic per token shape.
    /// 5d-twenty-eighth-improvement: also try to merge multi-token
    /// ranges like ["5", "-", "7,5"] → "5 - 7,5" before falling
    /// back to per-token classification. This handles the
    /// common OCR mess "5 - 7,5 0 - 0,1" where two ranges are
    /// emitted without their leading marker name.
    private static func classifyTokens(_ tokens: [String]) -> (String, String?, String?, String?) {
        var value: String? = nil
        var range: String? = nil
        var unit: String? = nil
        var comment: String? = nil
        var leftovers: [String] = []
        var idx = 0
        while idx < tokens.count {
            let t = tokens[idx]
            if isUnitToken(t) {
                unit = (unit.map { $0 + " " } ?? "") + t
                idx += 1
                continue
            }
            // Try to merge a multi-token range: <num> - <num>.
            if idx + 2 < tokens.count,
               isNumericish(tokens[idx]),
               tokens[idx + 1] == "-",
               isNumericish(tokens[idx + 2]) {
                let merged = "\(tokens[idx]) - \(tokens[idx + 2])"
                range = merged
                idx += 3
                continue
            }
            if isRangeToken(t) {
                range = t
                idx += 1
                continue
            }
            if isValueToken(t) {
                if value == nil { value = t } else { leftovers.append(t) }
                idx += 1
                continue
            }
            leftovers.append(t)
            idx += 1
        }
        if !leftovers.isEmpty {
            comment = leftovers.joined(separator: " ")
        }
        return (value ?? "", range, unit, comment)
    }

    private static func isNumericish(_ t: String) -> Bool {
        return !t.isEmpty && t.allSatisfy { "0123456789,.".contains($0) }
    }

    /// 5d-twenty-eighth: does this token look like a unit?
    private static func isUnitToken(_ t: String) -> Bool {
        let kws = ["/", "мкл", "мг", "ммоль", "мкмоль", "ед.", "поле зр", "препар", "мл/мин", "г/мл", "г/л", "мг/дл", "мг/л"]
        let lo = t.lowercased()
        for k in kws { if lo.contains(k) { return true } }
        return false
    }

    /// 5d-twenty-eighth: does this token look like a reference range?
    /// e.g. "1,008", "1,008-1,025", "1,008 - 1,025", "<3,4", ">5,0".
    private static func isRangeToken(_ t: String) -> Bool {
        let s = t.replacingOccurrences(of: " ", with: "")
        if s.isEmpty { return false }
        // Must contain a digit.
        guard s.contains(where: { $0.isNumber }) else { return false }
        // Reject pure text.
        if s.allSatisfy({ !$0.isNumber && $0 != "," && $0 != "." && $0 != "-" && $0 != "<" && $0 != ">" }) { return false }
        // Reject obvious non-range values.
        let lower = s.lowercased()
        if lower.contains("отрицательно") || lower.contains("обнаруж") { return false }
        // Accept if has digit, dash/dot/comma, OR comparison operator.
        let hasDigit = s.contains(where: { $0.isNumber })
        let hasRangeShape = s.contains("-") || s.contains("<") || s.contains(">")
        return hasDigit && hasRangeShape
    }

    /// 5d-twenty-eighth: does this token look like a value?
    /// Numeric, "отрицательно", "не обнаружено", "отсутствуют",
    /// "единичные", "небольшое", colour words, or partial range.
    private static func isValueToken(_ t: String) -> Bool {
        let lo = t.lowercased()
        let valueKeywords = ["не обнаружено", "отсутствуют", "отсутствует",
                             "отрицательно", "единичные", "небольшое",
                             "большое", "умеренное", "много", "мало",
                             "соломенно", "прозрачная", "мутная",
                             "желтый", "желтая", "в пре",
                             "в п/з", "в п/зр", "в поле зр"]
        for kw in valueKeywords {
            if lo.contains(kw) { return true }
        }
        // Pure numeric / range (treat as value).
        if t.allSatisfy({ "0123456789,.- ".contains($0) }) { return true }
        if let first = t.first, first.isNumber { return true }
        return false
    }

    /// 5d-twenty-eighth: entry point for Vision OCR text. Used by
    /// AddLabTestView scan path as an alternative to `parse(text:)`.
    /// Returns the same PDFParseResult so the rest of the pipeline
    /// (processAndVerify, LabTestDetailView) works without code
    /// changes.
    static func parseVision(text ocrText: String) -> PDFParseResult? {
        let cleaned = ocrText.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        guard cleaned.count > 200 else { return nil }
        let physchem = parseTableV2(in: cleaned, sectionHeader: "Физико-химические свойства")
        let micro    = parseTableV2(in: cleaned, sectionHeader: "Микроскопическое исследование осадка")
        var all: [PDFMarker] = []
        all.append(contentsOf: physchem)
        all.append(contentsOf: micro)
        // De-dup by name+value.
        var seen: Set<String> = []
        all = all.filter { m in
            let k = (m.name.lowercased()) + "|" + (m.value ?? "").lowercased()
            return seen.insert(k).inserted
        }
        // Drop markers with no value AND no range.
        all = all.filter { m in
            let hasValue = !(m.value?.isEmpty ?? true)
            let hasRange = !(m.referenceRange?.isEmpty ?? true)
            return !m.name.isEmpty && (hasValue || hasRange)
        }
        if all.count < 3 {
            print("[SomaAI] PDFNativeParser(vision): only \(all.count) markers (need >=3) — falling back")
            return nil
        }
        print("[SomaAI] PDFNativeParser(vision): recovered \(all.count) markers (physchem=\(physchem.count) micro=\(micro.count))")
        let patient = parsePatient(text: cleaned)
        return PDFParseResult(markers: all, patient: patient)
    }
}
