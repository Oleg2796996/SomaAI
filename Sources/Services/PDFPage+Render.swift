import UIKit
import PDFKit

extension PDFPage {
    /// Render a PDF page to UIImage at the given scale.
    /// - Scale 3.0 (final, 4.7ao-pdf-4): A4 = 1785x2526 px, comfortably
    ///   under Vision's effective processing ceiling on iOS 26.5 sim
    ///   (we now know the real limit is below 3369 — possibly around
    ///   3000 — because 4.0 still clipped the top half of the page).
    ///   3.0 gives ~0.31 confidence (4.7aj post-mortem) which is
    ///   "medium" by Sprint 4.7am thresholds — enough to pass the
    ///   quality gate and let regex/LLM extract the full table.
    /// - 4.0 (4.7ao-pdf-3) was a step in the right direction but still
    ///   over the limit; 2382x3369 produced 469 chars (only the bottom
    ///   half of the page). 5.0 (4.7aj) clipped to ~362 chars (just
    ///   the bottom 4 rows). 3.0 should return the full page text.
    /// - 1.0 reproduces the legacy `PDFPage.thumbnail(of:for:)` behaviour
    ///   but at unusable quality.
    func renderAsImage(scale: CGFloat = 3.0) -> UIImage? {
        let pageRect = bounds(for: .mediaBox)
        let pixelSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.cgContext.saveGState()
            // Sprint 4.7ak: PDF coordinate system has Y growing UPWARD
            // (origin bottom-left), UIGraphicsImageRenderer has Y growing
            // DOWNWARD (origin top-left, like UIKit). Without the flip,
            // draw(with:to:) renders text upside-down/mirrored — Vision
            // OCR returns 30% confidence and garbled output like
            // "ГОЯТС" instead of "СТРОГО". Translate to the bottom, then
            // scale Y by -1 to flip the page right-side up.
            ctx.cgContext.translateBy(x: 0, y: pageRect.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        // Sprint 4.7ao-pdf-3: log the render dimensions so the next
        // person debugging Vision OCR regressions can see at a glance
        // whether Vision is being handed a 3000x4200 image (over the
        // ~4096 limit on iOS 26.5 sim) or a 2380x3368 one (safe).
        print("[SomaAI] PDF render: pageRect=\(Int(pageRect.width))x\(Int(pageRect.height))pt -> \(Int(pixelSize.width))x\(Int(pixelSize.height))px (scale=\(scale))")
        return image
    }
}