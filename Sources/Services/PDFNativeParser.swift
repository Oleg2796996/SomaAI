// Sprint 4.7ao-pdf-5d-eleventh: extract markers DIRECTLY from
// PDFKit native text (PDFDocument.string), bypassing Vision OCR
// entirely for digital PDFs.
//
// CONTEXT: at 16:58 Oleg ran 5d-tenth (e500c6a) and got:
//   - Date 2025-11-07 from PDFKit string ✅
//   - markers=0, sections=11 ❌  (75s timeout hit before LLM call
//     finished because 4 Vision OCR calls × ~20s = 80s > 75s)
//
// On WSL pymupdf on the бланк НКЦ2 моча PDF showed the
// "Физико-химические свойства" and "Микроскопическое
// исследование осадка" tables are PURE SELECTABLE TEXT (not
// rasterised). All 25 markers live in pdf.string:
//
//   Цвет: соломенно-желтый, норма: соломенно-желтый
//   Прозрачность: прозрачная, норма: прозрачная
//   Относительная плотность: 1,027, норма: 1,008 - 1,025,
//     units: г/мл, comment: повышено
//   Реакция: 6, норма: 5 - 7,5
//   Белок: 0, норма: 0 - 0,1, units: г/л
//   ... (25 markers total)
//
// For these PDFs Vision OCR is overhead we don't need. We parse
// the native text directly, derive (name, value, unit,
// referenceRange) tuples, and only fall back to Vision OCR if
// the native parse yields < 5 markers (image-only PDF, or a
// layout our regex doesn't understand).
//
// The 4-column table layout in the НКЦ2 PDF is:
//
//   <Marker name>   <Result>   <Normal>   <Comment>   <Units>
//
// with columns separated by single newlines (PDFKit's default
// .string output puts each visual line on its own line). We
// parse the table by:
//   1. Splitting on the two section headers ("Физико-химические
//      свойства" and "Микроскопическое исследование осадка")
//   2. Within each section, recognising the header row
//      ("Показатель\nРезультат\nНорма\nКомментарий\nЕдиницы")
//   3. Then every 5 consecutive non-empty lines after the
//      header = one marker record.
//
// If parsing succeeds (>= 5 markers), we skip Vision OCR
// entirely. This collapses 4 Vision calls (~80s) into 0 calls
// (instant), avoiding the 75s processDocument timeout and
// removing Vision OCR's `value: null` non-determinism.

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

    /// Top-level result. `markers.isEmpty` indicates the caller
    /// should fall back to Vision OCR.
    struct PDFParseResult {
        let markers: [PDFMarker]
        let patient: PDFPatientInfo
    }

    /// Parse the PDF and extract markers + patient info.
    /// Returns nil if the PDF is too short to be a lab report.
    static func parse(pdf: PDFDocument) -> PDFParseResult? {
        guard let text = pdf.string, text.count > 200 else {
            return nil
        }

        // Patient info (best-effort regex).
        let patient = parsePatient(text: text)

        // Markers from the two known table sections.
        var markers: [PDFMarker] = []
        markers.append(contentsOf: parseTable(
            in: text,
            sectionHeader: "Физико-химические свойства"
        ))
        markers.append(contentsOf: parseTable(
            in: text,
            sectionHeader: "Микроскопическое исследование осадка"
        ))

        return PDFParseResult(markers: markers, patient: patient)
    }

    // MARK: - Patient

    private static func parsePatient(text: String) -> PDFPatientInfo {
        func firstMatch(of pattern: String) -> String? {
            guard let range = text.range(of: pattern, options: .regularExpression) else {
                return nil
            }
            // Take the rest of the line after the matched label.
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

    // MARK: - Tables

    /// Parse a 5-column table (Показатель | Результат | Норма |
    /// Комментарий | Единицы) starting at `sectionHeader`. Lines
    /// are separated by `\n` in PDFKit's `.string` output.
    private static func parseTable(in text: String, sectionHeader: String) -> [PDFMarker] {
        guard let headerRange = text.range(of: sectionHeader) else {
            return []
        }
        let after = text[headerRange.upperBound...]

        // Find the column header row. The PDF puts it as
        //   Показатель
        //   Результат
        //   Норма
        //   Комментарий
        //   Единицы
        // (each label on its own line, in order). We anchor on
        // "Показатель" + "Единицы" to confirm we're in the right
        // table.
        let lines = after.split(separator: "\n", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces) }
        var i = 0
        // Find the Показатель/Результат/Норма/Комментарий/Единицы
        // header sequence.
        while i + 4 < lines.count {
            if lines[i] == "Показатель"
                && lines[i + 1] == "Результат"
                && lines[i + 2] == "Норма"
                && (lines[i + 3] == "Комментарий" || lines[i + 3] == "Единицы")
                && lines[i + 4] == "Единицы" {
                break
            }
            i += 1
        }
        guard i + 4 < lines.count else { return [] }
        i += 5  // skip the header

        // Now read records: every 5 lines = (name, value, range,
        // comment, unit). But multi-line values like "соломенно -
        // желтый" (split across two PDF lines) break the simple
        // 5-line grouping. We do best-effort: skip empty lines,
        // take the first non-empty line as `name`, then the next
        // non-empty lines as value/range/comment/unit, stopping
        // when we hit a line that looks like the NEXT marker name
        // (no unit hint, no numeric pattern, no Russian
        // "не обнаружено"/"отсутствуют" pattern).
        var markers: [PDFMarker] = []
        let total = lines.count
        while i < total {
            // Skip empty lines.
            while i < total, lines[i].isEmpty { i += 1 }
            guard i < total else { break }

            let nameCandidate = lines[i]
            // If the line looks like a section break or footer,
            // stop.
            if nameCandidate.contains("Стр. ") || nameCandidate.contains("Анализы выполнены") {
                break
            }

            // Read up to 6 following lines as the value/range/
            // comment/unit tuple. Heuristic: take the first 4
            // non-empty lines as the 4 columns.
            var cols: [String] = []
            var j = i + 1
            while j < total && cols.count < 4 {
                if !lines[j].isEmpty {
                    cols.append(lines[j])
                }
                j += 1
            }
            // Heuristic columns: [value, range, comment, unit] OR
            // [value, range, unit] OR [value, range] depending on
            // how the PDF laid out the row.
            // НКЦ2 PDFs lay out as: value, range, comment, unit
            // (4 lines). But some rows merge the comment into
            // range or omit the unit. We assign heuristically.
            let value = cols.indices.contains(0) ? cols[0] : nil
            let referenceRange = cols.indices.contains(1) ? cols[1] : nil
            // If we have 4 cols: [value, range, comment, unit]
            // If 3 cols: [value, range, unit]
            // If 2 cols: [value, range]
            let comment: String?
            let unit: String?
            switch cols.count {
            case 4:
                comment = cols[2]
                unit = cols[3]
            case 3:
                // НКЦ2 4-line rows sometimes drop the comment.
                // The 3rd col is unit if it looks like a unit
                // (contains "/", "мкл", "г/л", "мкмоль", "ммоль",
                // "мг/", "ед." or is short and lowercase).
                let looksLikeUnit = cols[2].contains("/")
                    || cols[2].contains("мкл")
                    || cols[2].contains("мг")
                    || cols[2].contains("ммоль")
                    || cols[2].contains("мкмоль")
                    || cols[2].contains("в поле зр")
                    || cols[2].contains("в преп")
                    || cols[2] == "ед."
                if looksLikeUnit {
                    comment = nil
                    unit = cols[2]
                } else {
                    comment = cols[2]
                    unit = nil
                }
            default:
                comment = nil
                unit = nil
            }
            // Markers where value is "не обнаружено" / "отсутствуют"
            // / "отрицательно" / "единичные" don't need a flag;
            // pass through.
            markers.append(PDFMarker(
                name: nameCandidate,
                value: (value?.isEmpty == false) ? value : nil,
                unit: (unit?.isEmpty == false) ? unit : nil,
                referenceRange: (referenceRange?.isEmpty == false) ? referenceRange : nil,
                comment: (comment?.isEmpty == false) ? comment : nil
            ))
            i = j
        }
        return markers
    }
}
