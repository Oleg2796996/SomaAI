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

    /// Sprint 4.7ao-pdf-5b: render the full page once at scale 3.0, then
    /// split the resulting CGImage into top + bottom halves. This
    /// replaces the broken renderAsImageHalves() (4.7ao-pdf-5a) which
    /// tried to draw the page directly into a half-height CGContext
    /// using `draw(with:to:)` — but that method scales the whole page
    /// to fit the rect, it doesn't clip it. We ended up with
    /// squished, garbled halves (conf 0.42, 639 chars — WORSE than
    /// the un-split 0.87 / 1500+ char output).
    ///
    /// The correct way: render ONCE at full size (Vision's
    /// processing limit is below 2526 on iOS 26.5 sim — and at 3.0
    /// we already proved Vision can see the top, it just drops a few
    /// rows in the middle). After rendering, use CGImage.cropping(to:)
    /// to extract the two halves as separate UIImages. Each half
    /// is 1785 x 1263 px, comfortably under the limit, AND the
    /// Vision call sees only the content of that half (no squishing,
    /// no flip, no nonsense).
    func renderAsImageHalves(scale: CGFloat = 3.0) -> [UIImage] {
        guard let fullImage = renderAsImage(scale: scale),
              let cgFull = fullImage.cgImage else {
            // Fallback: just return the full image as a single
            // element so the caller still has something to OCR.
            // (Mirrors the pre-4.7ao-pdf-5a behaviour.)
            return renderAsImage(scale: scale).map { [$0] } ?? []
        }
        let w = cgFull.width
        let h = cgFull.height
        let halfH = h / 2
        var halves: [UIImage] = []
        for halfIndex in 0..<2 {
            // CGImage cropping coordinate system: origin top-left, Y
            // growing DOWN (UIKit convention — confirmed in Apple docs
            // for CGImage.cropping(to:)). So:
            //   top half    = y=0..halfH
            //   bottom half = y=halfH..h
            let cropRect: CGRect
            if halfIndex == 0 {
                cropRect = CGRect(x: 0, y: 0, width: w, height: halfH)
            } else {
                cropRect = CGRect(x: 0, y: halfH, width: w, height: halfH)
            }
            if let cropped = cgFull.cropping(to: cropRect) {
                halves.append(UIImage(cgImage: cropped, scale: 1.0, orientation: .up))
            }
        }
        print("[SomaAI] PDF render halves: fullImage=\(w)x\(h)px (scale=\(scale)) -> 2 halves at \(w)x\(halfH)px via CGImage.cropping")
        return halves
    }
}