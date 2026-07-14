import Foundation
import Vision
import UIKit

/// Vision-based OCR with multi-strategy fallback. The first attempt
/// runs auto-enhancement + accurate recognition with language
/// correction; if that returns poor quality, we retry with binarisation
/// and language correction off. Used by `AddLabTestView` for both
/// camera shots and PDF page renders.
public struct OCRResult {
    let text: String
    let quality: OCRQuality
    /// Average confidence across all lines, 0.0–1.0.
    let confidence: Float
    let pageCount: Int
}

public enum OCRQuality {
    case good, medium, poor
    /// Score used to surface the quality in the verification header.
    var label: String {
        switch self {
        case .good: return "OCR: good"
        case .medium: return "OCR: medium"
        case .poor: return "OCR: poor"
        }
    }
}

public final class OCRPipeline {
    static let shared = OCRPipeline()
    private let pre = ImagePreprocessor.shared

    /// Run the multi-strategy OCR on a single image. Returns the best
    /// of (enhanced + accurate + correction, binarized + accurate,
    /// no-correction). Never throws — falls back to empty string.
    ///
    /// Sprint 4.7q: when `useTableMode` is true (set for `labResult`
    /// documents), output is reformatted with column preservation using
    /// bounding-box aware grouping. Zero extra tokens — the LLM receives
    /// the same amount of text, but values stay aligned with their
    /// marker names in the same logical row.
    /// Sprint 4.7an: when isFromPDFRender is true, the image is a clean
    /// black-on-white text render from PDFKit (already high contrast),
    /// so autoEnhance (which lowers saturation to 0.9) makes the page
    /// GREY and Vision OCR drops the table rows. Bypass autoEnhance for
    /// PDF renders so Vision sees full black-on-white contrast.
    func process(image: UIImage, useTableMode: Bool = false, isFromPDFRender: Bool = false) async -> OCRResult {
        // Sprint 4.7ao-pdf-2: PDF renders at 5x scale on A4 make body
        // text 0.5-0.8% of page height. The previous minimumTextHeight
        // of 0.01 (1%) was dropping small numeric values, units, and
        // reference ranges — leaving only the lower, larger-font rows
        // ("Сперматозоиды...", "Анализы выполнены на оборудовании...",
        // "Стр. N из M"). Photos don't need this — they come in larger
        // and are already subject to autoEnhance, which compensates.
        let pdfMinHeight: Float = 0.006
        if useTableMode {
            let source = isFromPDFRender ? image : pre.autoEnhance(image)
            let minHeight: Float = isFromPDFRender ? pdfMinHeight : 0.01
            let (text, conf) = await TableAwareOCR.recognize(image: source, correction: false, minHeight: minHeight)
            return OCRResult(text: text,
                             quality: score(text: text, confidence: conf),
                             confidence: conf, pageCount: 1)
        }
        let source = isFromPDFRender ? image : pre.autoEnhance(image)
        // Photos keep the original 0.02 threshold (a high bar — they get
        // autoEnhance preprocessing and usually produce >1000 chars at
        // 0.02). PDFs use the much lower 0.006 to keep numeric values.
        let primaryMinHeight: Float = isFromPDFRender ? pdfMinHeight : 0.02
        let primary = await runVision(image: source, correction: true, minHeight: primaryMinHeight)
        let primaryQuality = score(text: primary.text, confidence: primary.confidence)
        if primaryQuality == .good || primaryQuality == .medium {
            return OCRResult(text: primary.text, quality: primaryQuality,
                             confidence: primary.confidence, pageCount: 1)
        }
        // Step 2: binarise + accurate + no language correction.
        // Sprint 4.7an: only binarize when source was enhanced (otherwise
        // the original is already high-contrast and binarize over-darkens).
        let binaryImage: UIImage
        if isFromPDFRender {
            binaryImage = source  // already clean
        } else {
            binaryImage = pre.binarize(source)
        }
        let fallback = await runVision(image: binaryImage, correction: false, minHeight: isFromPDFRender ? 0.006 : 0.01)
        if fallback.confidence > primary.confidence {
            return OCRResult(text: fallback.text, quality: score(text: fallback.text, confidence: fallback.confidence),
                             confidence: fallback.confidence, pageCount: 1)
        }
        return OCRResult(text: primary.text.isEmpty ? fallback.text : primary.text,
                         quality: .poor, confidence: max(primary.confidence, fallback.confidence),
                         pageCount: 1)
    }

    /// Multi-page variant: returns concatenated text and the worst
    /// single-page quality. Each page is reformatted with table mode
    /// when enabled, so the column structure survives page boundaries.
    /// Sprint 4.7an: caller passes isFromPDFRender=true for clean PDF
    /// renders (skip autoEnhance). For photos (default false) the
    /// enhancement chain stays active.
    func process(pages: [UIImage], useTableMode: Bool = false, isFromPDFRender: Bool = false) async -> OCRResult {
        guard !pages.isEmpty else { return OCRResult(text: "", quality: .poor, confidence: 0, pageCount: 0) }
        var combined = ""
        var worst: OCRQuality = .good
        var confSum: Float = 0
        for (i, page) in pages.enumerated() {
            let r = await process(image: page, useTableMode: useTableMode, isFromPDFRender: isFromPDFRender)
            if r.quality == .poor { worst = .poor }
            else if r.quality == .medium && worst == .good { worst = .medium }
            combined += "--- Page \(i + 1) ---\n\(r.text)\n\n"
            confSum += r.confidence
        }
        return OCRResult(text: combined, quality: worst,
                         confidence: confSum / Float(pages.count),
                         pageCount: pages.count)
    }

    // MARK: - Vision

    private struct VisionOutcome {
        let text: String
        let confidence: Float
    }

    private func runVision(image: UIImage, correction: Bool, minHeight: Float) async -> VisionOutcome {
        guard let cgImage = image.cgImage else { return VisionOutcome(text: "", confidence: 0) }
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { req, _ in
                let observations = (req.results as? [VNRecognizedTextObservation]) ?? []
                let candidates = observations.compactMap { $0.topCandidates(1).first }
                let text = candidates.map { $0.string }.joined(separator: "\n")
                let conf = candidates.isEmpty ? 0
                    : candidates.map { $0.confidence }.reduce(0, +) / Float(candidates.count)
                continuation.resume(returning: VisionOutcome(text: text, confidence: conf))
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ru-RU", "en-US"]
            request.usesLanguageCorrection = correction
            request.minimumTextHeight = minHeight
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch {
                continuation.resume(returning: VisionOutcome(text: "", confidence: 0))
            }
        }
    }

    // MARK: - Quality scoring

    /// Sprint 4.7am: loosened thresholds so PDF scans (where Vision on iOS
    /// 26.5 simulator caps at ~50-65% confidence for Russian text) don't
    /// get rejected as "poor". Was: .good requires >0.7 confidence AND
    /// >30% cyrillic, .medium requires >0.3 cyrillic — both unrealistic
    /// for medical PDF scans. New: trust cyrillicRatio (real text) and
    /// downgrade confidence bar to >0.5 for good, >0.3 for medium.
    private func score(text: String, confidence: Float) -> OCRQuality {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cyrillic = trimmed.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        let total = max(1, trimmed.count)
        let cyrillicRatio = Float(cyrillic) / Float(total)
        // Real text in Russian lab reports: usually 30-70% cyrillic.
        // Numbers, dashes, punctuation, and unit names (g/l, ммоль/л)
        // account for the rest. So cyrillicRatio > 0.15 is reliable.
        if trimmed.count > 1000 && cyrillicRatio > 0.15 && confidence > 0.5 { return .good }
        if trimmed.count > 500 && cyrillicRatio > 0.10 { return .medium }
        if trimmed.count > 200 && cyrillicRatio > 0.05 { return .medium }
        return .poor
    }
}