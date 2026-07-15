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

        var markers: [PDFMarker] = []
        let m1 = parseTable(in: text, sectionHeader: "Физико-химические свойства")
        print("[SomaAI] PDFNativeParser: Физико-химические = \(m1.count) markers")
        markers.append(contentsOf: m1)
        let m2 = parseTable(in: text, sectionHeader: "Микроскопическое исследование осадка")
        print("[SomaAI] PDFNativeParser: Микроскопическое = \(m2.count) markers")
        markers.append(contentsOf: m2)
        print("[SomaAI] PDFNativeParser: total = \(markers.count) markers")
        for (idx, m) in markers.prefix(3).enumerated() {
            print("[SomaAI]   marker[\(idx)]: name='\(m.name)' value='\(m.value ?? "nil")' range='\(m.referenceRange ?? "nil")' unit='\(m.unit ?? "nil")'")
        }
        return PDFParseResult(markers: markers, patient: patient)
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

    /// Heuristic: is this line a marker NAME (Cyrillic title that
    /// doesn't start with a digit, isn't a number, isn't a known
    /// stop/header line)?
    ///
    /// CRITICAL: in pdf.string from iOS PDFKit, marker names are
    /// followed by value lines. The value lines can be Cyrillic
    /// ("соломенно", "желтый", "прозрачная", "единичные") or
    /// numeric ("1,027", "0 - 0,1"). To avoid mis-classifying
    /// values as marker names, we use a STRICT whitelist of
    /// known marker names from НКЦ2 lab PDFs.
    private static func isMarkerName(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        // Reject known stop lines.
        if stopLines.contains(t) { return false }
        if sectionHeaders.contains(t) { return false }
        // Reject pure numerics / ranges.
        if t.allSatisfy({ "0123456789,.- \t".contains($0) }) { return false }
        // Reject lines that start with a digit.
        if t.first?.isNumber == true { return false }
        // Reject value-shaped lines (numeric range, "не обнаружено",
        // "отсутствуют", "отрицательно", "единичные", "небольшое",
        // color words like "желтый", "прозрачная", "соломенно").
        if isValue(t) { return false }
        // Reject unit-shaped lines.
        if isUnit(t) { return false }
        // Reject short lines (< 3 chars) that are likely fragments.
        guard t.count >= 3 else { return false }
        // Reject lines that are pure lowercase Russian (likely
        // comments / values, not marker names). Marker names
        // typically start with a capital letter.
        let firstChar = t.first!
        if firstChar.isLowercase { return false }
        return true
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

            let name = lines[i]
            // Stop at section boundary or footer.
            if stopLines.contains(name) { break }
            if sectionHeaders.contains(name) { break }

            // If this is not a marker name, just skip it.
            guard isMarkerName(name) else {
                i += 1
                continue
            }

            // Read the next non-empty lines until we hit the next
            // marker name or section boundary.
            var rowLines: [String] = []
            var j = i + 1
            while j < total {
                let l = lines[j]
                if l.isEmpty { j += 1; continue }
                if stopLines.contains(l) || sectionHeaders.contains(l) { break }
                if isMarkerName(l) { break }
                rowLines.append(l)
                j += 1
                // Don't collect forever — cap at 6 lines per row
                // to avoid eating the next section.
                if rowLines.count >= 6 { break }
            }

            // Classify the row lines: first non-empty is value,
            // second is range, third is comment or unit (depending
            // on shape), fourth is the remaining.
            // Heuristic: if a line looks like a unit, it's the
            // unit. If a line looks like a value AND has no digits,
            // it's a value or range. If a line is long Russian
            // text (>15 chars and not a unit), it's a comment.
            var value: String? = nil
            var range: String? = nil
            var unit: String? = nil
            var comment: String? = nil

            // The first line in rowLines is almost always the value.
            if !rowLines.isEmpty {
                value = rowLines[0]
            }
            // The second is usually the range (it's a numeric or
            // "не обнаружено").
            if rowLines.count >= 2 {
                range = rowLines[1]
            }
            // Lines 3+ — figure out which is unit and which is
            // comment. Unit if matches isUnit; comment otherwise.
            for k in 2..<rowLines.count {
                let l = rowLines[k]
                if isUnit(l) && unit == nil {
                    unit = l
                } else if comment == nil {
                    // If the line contains a digit and looks like
                    // an "X-Y" pattern, treat as range continuation.
                    if l.contains("-") && l.allSatisfy({ "0123456789,-. ".contains($0) || $0.isLetter }) {
                        if let r = range, r.contains("-") {
                            // already have a range, treat as comment
                            comment = l
                        } else {
                            range = l
                        }
                    } else {
                        comment = l
                    }
                }
            }

            // If the marker name is purely "Цвет" or similar and
            // the value/range got split (e.g. "соломенно -" /
            // "желтый"), join them.
            if let v = value, v.hasSuffix(" -") || v == "соломенно" {
                if let next = rowLines.dropFirst().first {
                    value = v + " " + next
                    // shift: the next line is consumed.
                    if rowLines.count >= 2 { range = rowLines.count >= 3 ? rowLines[2] : nil }
                    if rowLines.count >= 4 { /* unit = rowLines[3] */ }
                    if rowLines.count >= 5 { /* comment = rowLines[4] */ }
                }
            }
            if let r = range, r.hasSuffix(" -") || r == "соломенно" {
                if let next = rowLines.dropFirst().first {
                    range = r + " " + next
                }
            }

            markers.append(PDFMarker(
                name: name,
                value: (value?.isEmpty == false) ? value : nil,
                unit: (unit?.isEmpty == false) ? unit : nil,
                referenceRange: (range?.isEmpty == false) ? range : nil,
                comment: (comment?.isEmpty == false) ? comment : nil
            ))
            i = j
        }
        return markers
    }
}
