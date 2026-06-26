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
    func process(image: UIImage) async -> OCRResult {
        // Step 1: auto-enhance (works for >95% of photos)
        let enhanced = pre.autoEnhance(image)
        let primary = await runVision(image: enhanced, correction: true, minHeight: 0.02)
        let primaryQuality = score(text: primary.text, confidence: primary.confidence)
        if primaryQuality == .good || primaryQuality == .medium {
            return OCRResult(text: primary.text, quality: primaryQuality,
                             confidence: primary.confidence, pageCount: 1)
        }
        // Step 2: binarise + accurate + no language correction.
        let binary = pre.binarize(enhanced)
        let fallback = await runVision(image: binary, correction: false, minHeight: 0.01)
        // Pick the higher-confidence result.
        if fallback.confidence > primary.confidence {
            return OCRResult(text: fallback.text, quality: score(text: fallback.text, confidence: fallback.confidence),
                             confidence: fallback.confidence, pageCount: 1)
        }
        return OCRResult(text: primary.text.isEmpty ? fallback.text : primary.text,
                         quality: .poor, confidence: max(primary.confidence, fallback.confidence),
                         pageCount: 1)
    }

    /// Multi-page variant: returns concatenated text and the worst
    /// single-page quality.
    func process(pages: [UIImage]) async -> OCRResult {
        guard !pages.isEmpty else { return OCRResult(text: "", quality: .poor, confidence: 0, pageCount: 0) }
        var combined = ""
        var worst: OCRQuality = .good
        var confSum: Float = 0
        for (i, page) in pages.enumerated() {
            let r = await process(image: page)
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

    private func score(text: String, confidence: Float) -> OCRQuality {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cyrillic = trimmed.unicodeScalars.filter { (0x0400...0x04FF).contains($0.value) }.count
        let total = max(1, trimmed.count)
        let cyrillicRatio = Float(cyrillic) / Float(total)
        if trimmed.count > 1000 && cyrillicRatio > 0.30 && confidence > 0.7 { return .good }
        if trimmed.count > 500 && cyrillicRatio > 0.10 { return .medium }
        return .poor
    }
}