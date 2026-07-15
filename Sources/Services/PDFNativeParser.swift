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
        print("[SomaAI] PDFNativeParser(coord): Микроскопическое = \(m2c.count) markers")
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

    // MARK: - Coordinate-based parser (5d-fifteenth)

    /// Build coord-aware lines from a PDFPage. PDFKit's
    /// `selectionsForLine()` returns one PDFSelection per visual line
    /// (groups of fragments on the same Y). We further split each
    /// selection by horizontal gaps to get separate words.
    private static func coordLines(in page: PDFPage) -> [(y: CGFloat, frags: [(text: String, x: CGFloat)])] {
        var out: [(y: CGFloat, frags: [(text: String, x: CGFloat)])] = []
        for sel in page.selections(for: .line) {
            let bounds = sel.bounds(for: page)
            let y = bounds.origin.y
            var fragments: [(text: String, x: CGFloat)] = []
            for charSel in sel.selections(for: .character) {
                let charBounds = charSel.bounds(for: page)
                let c = charSel.string ?? ""
                if c.isEmpty { continue }
                if let last = fragments.last,
                   abs(last.x - charBounds.origin.x) < 1.0 {
                    fragments[fragments.count - 1] = (last.text + c, last.x)
                } else {
                    fragments.append((c, charBounds.origin.x))
                }
            }
            if !fragments.isEmpty {
                out.append((y: y, frags: fragments))
            }
        }
        return out
    }

    /// Group coord lines into rows (rows within `rowGap` of each
    /// other share the same row). Returns rows top-to-bottom.
    private static func groupRows(_ lines: [(y: CGFloat, frags: [(text: String, x: CGFloat)])], rowGap: CGFloat = 4) -> [[(text: String, x: CGFloat, y: CGFloat)]] {
        guard !lines.isEmpty else { return [] }
        // PDFKit's bounds(for: page) returns rect in page coords
        // (origin at bottom-left). Visual "top" = higher Y. Sort
        // DESCENDING by Y for top-to-bottom reading.
        let sorted = lines.sorted { $0.y > $1.y }
        var rows: [[(text: String, x: CGFloat, y: CGFloat)]] = []
        for line in sorted {
            let flat = line.frags.map { (text: $0.text, x: $0.x, y: line.y) }
            if let last = rows.last, let prev = last.first,
               abs(prev.y - line.y) <= rowGap {
                rows[rows.count - 1].append(contentsOf: flat)
            } else {
                rows.append(flat)
            }
        }
        return rows
    }

    /// Cluster a row's fragments into columns by horizontal gap.
    private static func clusterColumns(frags: [(text: String, x: CGFloat, y: CGFloat)], gap: CGFloat = 10) -> [String] {
        guard !frags.isEmpty else { return [] }
        let sorted = frags.sorted { $0.x < $1.x }
        var columns: [[(text: String, x: CGFloat)]] = [[sorted[0]]]
        for f in sorted.dropFirst() {
            let prev = columns[columns.count - 1].last!
            if f.x - prev.x > gap {
                columns.append([f])
            } else {
                columns[columns.count - 1].append(f)
            }
        }
        return columns.map { $0.map { $0.text }.joined() }
    }

    /// Column-based table parser. Walks all PDFPages and extracts
    /// markers by clustering text fragments into columns (separated
    /// by horizontal gaps) and rows (separated by vertical gaps).
    private static func parseTableByCoords(in pdf: PDFDocument,
                                           pageRange: ClosedRange<Int>,
                                           sectionHeader: String,
                                           debugName: String) -> [PDFMarker] {
        var markers: [PDFMarker] = []
        for pageIdx in pageRange {
            guard let page = pdf.page(at: pageIdx) else { continue }
            let lines = coordLines(in: page)
            let rows = groupRows(lines)
            print("[SomaAI] coordParse[\(debugName).p\(pageIdx)]: \(rows.count) rows from \(lines.count) selections")
            // Find the section header row.
            var sectionStart: Int? = nil
            for (idx, row) in rows.enumerated() {
                let rowText = row.map { $0.text }.joined()
                if rowText.contains(sectionHeader) {
                    sectionStart = idx
                    break
                }
            }
            guard let start = sectionStart else {
                print("[SomaAI] coordParse[\(debugName).p\(pageIdx)]: section header '\(sectionHeader)' not found")
                continue
            }
            // Skip column header rows (Показатель/Результат/Норма/...)
            var i = start + 1
            var skipped = 0
            while i < rows.count && skipped < 3 {
                let row = rows[i]
                let cols = clusterColumns(frags: row)
                let first = cols.first ?? ""
                let isColumnHeader =
                    first.contains("Показатель") ||
                    first.contains("Результат") ||
                    first == "Комментарий" ||
                    first.isEmpty
                if isColumnHeader { skipped += 1; i += 1; continue }
                break
            }
            // Parse markers.
            while i < rows.count {
                let row = rows[i]
                let cols = clusterColumns(frags: row)
                guard let first = cols.first else { i += 1; continue }
                if sectionHeaders.contains(first) { break }
                if stopLines.contains(first) { break }
                if first.isEmpty || first.contains("Показатель") {
                    i += 1; continue
                }
                guard first.first?.isUppercase == true else { i += 1; continue }
                guard first.count >= 3 else { i += 1; continue }
                guard !isValue(first), !isUnit(first) else { i += 1; continue }
                let name = first
                let value = cols.count > 1 ? cols[1] : nil
                let range = cols.count > 2 ? cols[2] : nil
                var unit: String? = nil
                var comment: String? = nil
                if cols.count > 3 {
                    let c3 = cols[3]
                    if isUnit(c3) { unit = c3 }
                    else { comment = c3 }
                }
                if cols.count > 4 { comment = cols[4] }
                markers.append(PDFMarker(
                    name: name,
                    value: (value?.isEmpty == false) ? value : nil,
                    unit: (unit?.isEmpty == false) ? unit : nil,
                    referenceRange: (range?.isEmpty == false) ? range : nil,
                    comment: (comment?.isEmpty == false) ? comment : nil
                ))
                i += 1
            }
        }
        return markers
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
}
