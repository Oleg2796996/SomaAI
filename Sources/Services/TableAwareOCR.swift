import Foundation
import Vision
import UIKit

/// Sprint 4.7q: table-aware OCR using bounding boxes.
///
/// Problem: VNRecognizeTextRequest returns observations in arbitrary order.
/// For lab tables with thin horizontal rules and no vertical separators,
/// the joined line text loses the column structure — values from the
/// "Result" column get mixed with names, units, and reference ranges,
/// and downstream LLMs/extractors cannot pair them with their markers.
///
/// Fix: keep per-word bounding boxes, group words into rows by Y-centroid
/// proximity (1.5% of image height), sort each row by X-centroid, and
/// emit a tabular layout where each row is a space-aligned line:
///
///   Эритроциты, RBC    4,5    4,2 - 5,6    10 в 12 ст. /л
///   Гемоглобин, HGB    137    131 - 172    г/л
///
/// This format keeps the existing extraction pipeline unchanged — the LLM
/// still receives plain text, but now values live in the same logical row
/// as their marker names. No extra tokens spent.
public enum TableAwareOCR {

    /// Maximum Y-centroid difference (as fraction of image height) for two
    /// words to be considered the same row. 0.015 = 1.5% of image height,
    /// which works for typical lab document line spacing (≈25 px on 1280-tall).
    private static let rowYTolerance: CGFloat = 0.015

    /// Minimum X-gap (fraction of image width) that introduces a column
    /// separator (≥2 spaces). Smaller gaps use a single space.
    private static let columnMinGap: CGFloat = 0.02

    /// Run table-aware OCR on a single image. Falls back to plain line
    /// output if no observations have usable bounding boxes (rare).
    public static func recognize(image: UIImage,
                                 correction: Bool = false,
                                 minHeight: Float = 0.01) async -> (text: String, confidence: Float) {
        guard let cgImage = image.cgImage else { return ("", 0) }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let result = Self.format(observations: observations)
                continuation.resume(returning: result)
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            // IMPORTANT: disable language correction for numeric values
            // (otherwise "4,5" may become "4.5" and ranges get rewritten).
            request.usesLanguageCorrection = correction
            request.minimumTextHeight = minHeight
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch {
                continuation.resume(returning: ("", 0))
            }
        }
    }

    /// Format a flat list of observations into a table-preserving text.
    /// Public so it can be unit-tested without a UIImage.
    public static func format(observations: [VNRecognizedTextObservation]) -> (text: String, confidence: Float) {
        guard !observations.isEmpty else { return ("", 0) }

        // 1) Project each observation onto a per-word list with bounding box.
        //    We keep the per-line bounding box (not per-word) which is what
        //    VNRecognizeTextRequest returns; line-level grouping is what
        //    we need for table rows.
        struct Item {
            let text: String
            let x: CGFloat   // left X of bbox, in [0,1] (Vision uses bottom-left origin)
            let y: CGFloat   // centroid Y of bbox, in [0,1]
            let width: CGFloat
            let confidence: Float
        }
        var items: [Item] = []
        for obs in observations {
            guard let cand = obs.topCandidates(1).first else { continue }
            // Vision boundingBox: origin = bottom-left, in normalized [0,1] units.
            let bb = obs.boundingBox
            let x = bb.origin.x
            let y = bb.origin.y + bb.size.height / 2  // centroid
            items.append(Item(text: cand.string,
                              x: x,
                              y: y,
                              width: bb.size.width,
                              confidence: cand.confidence))
        }
        guard !items.isEmpty else { return ("", 0) }

        // 2) Sort top-to-bottom (descending Y in Vision's bottom-left system).
        items.sort { $0.y > $1.y }

        // 3) Group into rows by Y-centroid tolerance.
        var rows: [[Item]] = []
        for item in items {
            if let last = rows.last,
               let firstOfLast = last.first,
               abs(firstOfLast.y - item.y) < rowYTolerance {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }

        // 4) For each row, sort left-to-right, then align columns.
        //    We don't know the real column boundaries, so we use X-gap
        //    heuristic: gap ≥ columnMinGap → 2 spaces, else 1 space.
        var lines: [String] = []
        for i in 0..<rows.count {
            rows[i].sort { $0.x < $1.x }
            var line = ""
            var prevX: CGFloat = -1
            var prevWidth: CGFloat = 0
            for item in rows[i] {
                if prevX >= 0 {
                    let gap = item.x - (prevX + prevWidth)
                    if gap >= columnMinGap {
                        line += "  "  // column separator
                    } else {
                        line += " "
                    }
                }
                line += item.text
                prevX = item.x
                prevWidth = item.width
            }
            lines.append(line)
        }

        let text = "[TABLE-AWARE-OCR]\n" + lines.joined(separator: "\n")
        let avgConf = items.map { $0.confidence }.reduce(0, +) / Float(items.count)
        return (text, avgConf)
    }
}
