import UIKit
import PDFKit

extension PDFPage {
    /// Render a PDF page to UIImage at the given scale.
    /// - Scale 2.5 (was 3.0 from 4.7ao-pdf-4 to 4.7ao-pdf-5b).
    ///   The 3.0 scale was a footgun: UIGraphicsImageRenderer applies
    ///   UIScreen.main.scale ON TOP of the requested scale, so on
    ///   iPhone 6.5" Pro Retina sims (scale=3.0) we were producing
    ///   9.0x renders (1786x2526 logical -> 5360x7581 actual pixels).
    ///   Vision then clipped the top half of the page in EACH half,
    ///   and the resulting 705 chars / conf 0.29 / 0 markers run was
    ///   strictly worse than the un-split 1786x2526 output from
    ///   4.7ao-pdf-4 (1500+ chars / conf 0.87 / 8+ markers).
    /// - 2.5 with UIGraphicsImageRendererFormat.scale=1.0 gives
    ///   pixel-accurate A4 = 1487x2102 px (under the 2526 long-side
    ///   limit on iOS 26.5 sim) and uses 2.5x of the device's
    ///   screen-aspect pixel resolution, which Vision handles well.
    /// - 1.0 reproduces the legacy `PDFPage.thumbnail(of:for:)` behaviour
    ///   but at unusable quality.
    func renderAsImage(scale: CGFloat = 2.5) -> UIImage? {
        let pageRect = bounds(for: .mediaBox)
        let pixelSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        // Sprint 4.7ao-pdf-5c: pin UIGraphicsImageRenderer's internal
        // scale to 1.0 so the resulting UIImage is exactly
        // pixelSize in pixels. Without this, the renderer multiplies
        // by UIScreen.main.scale (3.0 on iPhone 6.5" Pro sim) and we
        // end up with 9x renders even when we asked for 3x.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
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
        print("[SomaAI] PDF render: pageRect=\(Int(pageRect.width))x\(Int(pageRect.height))pt -> \(Int(image.size.width))x\(Int(image.size.height))pt (scale=\(scale), pixelSize=\(Int(pixelSize.width))x\(Int(pixelSize.height))px)")
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
    func renderAsImageHalves(scale: CGFloat = 2.5) -> [UIImage] {
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