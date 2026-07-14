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

    /// Sprint 4.7ao-pdf-5a: split a page into top and bottom halves,
    /// each rendered separately. Necessary because Vision on iOS 26.5
    /// sim has an effective processing ceiling somewhere between 2526
    /// (where 3.0x mostly works but still misses the top header band
    /// with the document date and patient name) and 3369 (where 4.0x
    /// clips half the page). Even at 3.0x the first row was being
    /// dropped in testing — splitting guarantees both halves are
    /// well under the limit and the OCR pipeline sees the full page.
    ///
    /// Returns [top, bottom] at the same scale. If a half comes back
    /// empty, it's still returned as a white image of the right size
    /// so OCR gets a chance (and downstream logic doesn't have to
    /// special-case page count).
    func renderAsImageHalves(scale: CGFloat = 3.0) -> [UIImage] {
        let pageRect = bounds(for: .mediaBox)
        let halfHeight = pageRect.height / 2
        var halves: [UIImage] = []
        for halfIndex in 0..<2 {
            // PDF coordinate system: Y grows UPWARD, origin bottom-left.
            // The "top" of the page is pageRect.maxY (largest Y), and we
            // draw the top half by translating to (pageRect.minY + halfHeight)
            // and clipping to the top region.
            let halfOriginY = pageRect.minY + (CGFloat(1 - halfIndex) * halfHeight)
            // CGRect in PDF (Y-up) coords: x=0, y=halfOriginY, w=width, h=halfHeight
            let halfRect = CGRect(x: pageRect.minX,
                                  y: halfOriginY,
                                  width: pageRect.width,
                                  height: halfHeight)
            let pixelSize = CGSize(width: pageRect.width * scale, height: halfHeight * scale)
            let renderer = UIGraphicsImageRenderer(size: pixelSize)
            let image = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: pixelSize))
                ctx.cgContext.saveGState()
                // Same Y-flip as renderAsImage(): translate to the bottom
                // of the half, then scale Y by -1 to flip right-side up.
                ctx.cgContext.translateBy(x: 0, y: halfRect.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)
                // Clip to the half in PDF coordinates so draw() doesn't
                // paint outside it.
                ctx.cgContext.clip(to: CGRect(x: 0,
                                               y: 0,
                                               width: halfRect.width,
                                               height: halfRect.height))
                // Move the half-rect to origin (0..width x 0..halfHeight)
                // in the *flipped* coord system.
                ctx.cgContext.translateBy(x: -halfRect.minX, y: -halfRect.minY)
                draw(with: .mediaBox, to: ctx.cgContext)
                ctx.cgContext.restoreGState()
            }
            halves.append(image)
        }
        print("[SomaAI] PDF render halves: pageRect=\(Int(pageRect.width))x\(Int(pageRect.height))pt -> 2 halves at \(Int(pageRect.width * scale))x\(Int(halfHeight * scale))px (scale=\(scale))")
        return halves
    }
}