import UIKit
import PDFKit

extension PDFPage {
    /// Render a PDF page to UIImage at the given scale.
    /// - Scale 3.0 (restored after the 4.7ao-pdf-5c experiment).
    ///   The Retina multiplier that UIGraphicsImageRenderer applies
    ///   on top of user scale (3.0 * UIScreen.main.scale = 9.0x on
    ///   iPhone 6.5" Pro) is actually GOOD for OCR: it gives 216 DPI,
    ///   which is what professional scanners produce. The 4.7ao-pdf-4
    ///   run (scale=3.0, Retina-on, 5360x7581 physical pixels) was
    ///   the best result in the whole session — 8+ markers, conf 0.87
    ///   — and the 4.7ao-pdf-5c attempt to remove that multiplier
    ///   (scale=2.5, format.scale=1.0 -> 1487x2102 px, 180 DPI) gave
    ///   strictly worse OCR: 781 chars, conf 0.59, 0 markers.
    /// - The reason we couldn't get the document date wasn't the
    ///   render quality. It was that the page HEADER band (top ~10%
    ///   of the page, where the patient name, lab name and the sample
    ///   collection date live) was being dropped by Vision no matter
    ///   what we did to the scale, because the rest of the page
    ///   fills the whole Vision frame and the top rows fall outside
    ///   the OCR region. The fix is 4.7ao-pdf-5d: split into header
    ///   + body crops and OCR each separately.
    /// - 1.0 reproduces the legacy `PDFPage.thumbnail(of:for:)` behaviour
    ///   but at unusable quality.
    func renderAsImage(scale: CGFloat = 3.0) -> UIImage? {
        let pageRect = bounds(for: .mediaBox)
        let pixelSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        // Intentionally NOT setting format.scale = 1.0: we want the
        // Retina multiplier from UIScreen.main.scale. The output
        // UIImage will be pixelSize in *points* and pixelSize * 3
        // in *pixels* (on iPhone 6.5" Pro sim), which gives Vision
        // 216 DPI to work with.
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
        print("[SomaAI] PDF render: pageRect=\(Int(pageRect.width))x\(Int(pageRect.height))pt -> \(Int(image.size.width))x\(Int(image.size.height))pt (scale=\(scale), cgImage=\(image.cgImage.map { "\($0.width)x\($0.height)px" } ?? "nil"))")
        return image
    }

    /// Sprint 4.7ao-pdf-5b: render the full page once at scale 3.0, then
    /// Sprint 4.7ao-pdf-5d: render the full page once at scale 3.0
    /// (Retina-on, 5360x7581 physical px on iPhone 6.5" Pro sim) and
    /// split the resulting CGImage into a HEADER band and a BODY
    /// band. The Vision call is then made twice per page — once for
    /// each band.
    ///
    /// Why header+body and not 50/50? Because the failure mode of
    /// the unsplit run (4.7ao-pdf-4) was that the HEADER was
    /// consistently dropped (OCR always started with "Показатель
    /// Результат Норма", never with the patient name, lab name or
    /// sample collection date). A 50/50 split (4.7ao-pdf-5a/5b) is
    /// too coarse — it wastes OCR budget on the middle of the page
    /// while still possibly clipping the date in the upper part of
    /// the top half.
    ///
    /// Sprint 4.7ao-pdf-5d-ter: header 25% -> 35%. Oleg's 14:19 log
    /// shows the OCR preview from a 4.7ao-pdf-5c-style build (he
    /// hadn't rebuilt to 5d) — and even then the OCR text starts
    /// with "Показатель Результат Норма", with NO patient name /
    /// lab name / sample date ("07.11.2025") anywhere in the
    /// output. That means on НКЦ2 lab PDFs the header band that
    /// contains those fields is in roughly the top 30% of the page
    /// (clinic name at ~5%, patient name at ~10-15%, sample
    /// collection date at ~20-25%, lab technician signature
    /// at ~30%). 25% misses the date; 35% catches it.
    ///
    /// CGImage.cropping is the Apple-blessed way to slice a rendered
    /// image. The crop rect's origin is top-left, Y growing down
    /// (UIKit convention — verified against Apple docs for
    /// CGImage.cropping(to:)). Header = y=0..headerH. Body =
    /// y=headerH..h.
    func renderAsImageHalves(scale: CGFloat = 3.0) -> [UIImage] {
        guard let fullImage = renderAsImage(scale: scale),
              let cgFull = fullImage.cgImage else {
            // Sprint 4.7ao-pdf-5d-quater: the old fallback
            //   `return renderAsImage(scale: scale).map { [$0] } ?? []`
            // returned the FULL page as a single band, which made
            // this function equivalent to the un-split run — Vision
            // dropped the header and we got the bug back. Now we
            // return a synthetic half-by-half split by re-rendering
            // each page's media box to two distinct CGContexts
            // clipped to headerH and pageRect.height - headerH.
            // This is heavier (two render passes) but it always
            // works on iOS 26.5 regardless of cgImage state.
            return renderAsImageSplitFallback(scale: scale)
        }
        let w = cgFull.width
        let h = cgFull.height
        // Sprint 4.7ao-pdf-5d-ter: 35% header (was 25%). At
        // 5360x7581 physical px this is 5360x2653 — enough to cover
        // the patient name + lab name + sample collection date +
        // the lab technician signature row that usually sits at
        // ~30% on НКЦ2 lab PDFs.
        let headerH = Int(Double(h) * 0.35)
        let bodyH = h - headerH
        var bands: [UIImage] = []
        // Header band: top 35% of the page
        let headerRect = CGRect(x: 0, y: 0, width: w, height: headerH)
        if let header = cgFull.cropping(to: headerRect) {
            bands.append(UIImage(cgImage: header, scale: 1.0, orientation: .up))
        }
        // Body band: bottom 65%
        let bodyRect = CGRect(x: 0, y: headerH, width: w, height: bodyH)
        if let body = cgFull.cropping(to: bodyRect) {
            bands.append(UIImage(cgImage: body, scale: 1.0, orientation: .up))
        }
        print("[SomaAI] PDF render halves: fullImage=\(w)x\(h)px (scale=\(scale)) -> header \(w)x\(headerH)px (35%) + body \(w)x\(bodyH)px (65%) via CGImage.cropping")
        return bands
    }

    /// Sprint 4.7ao-pdf-5d-quater: re-render the page twice, once
    /// for the header region and once for the body region, using
    /// CGContext clipRect so that PDFPage.draw actually paints only
    /// the requested Y range (unlike `draw(with:to:)` which squishes
    /// the page into the rect, and unlike `CGImage.cropping` which
    /// requires a non-nil cgImage that UIGraphicsImageRenderer
    /// sometimes doesn't expose).
    private func renderAsImageSplitFallback(scale: CGFloat) -> [UIImage] {
        let pageRect = bounds(for: .mediaBox)
        let headerH = pageRect.height * 0.35
        let pixelSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        var bands: [UIImage] = []
        // Header band: render full page, but clip the context to
        // headerH so draw(with:to:) only fills that region.
        let headerImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: pageRect.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            // Clip to the header Y-range. We need the clip in PDF
            // coords (Y up) which means we translate first, then
            // clip in those coords. CGRect here is in the post-
            // transform coord space (PDF coords).
            ctx.cgContext.clip(to: CGRect(x: 0, y: pageRect.height - headerH, width: pageRect.width, height: headerH))
            draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        bands.append(headerImage)
        // Body band: full page, but again with clip to skip header
        let bodyImage = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: pageRect.height)
            ctx.cgContext.scaleBy(x: scale, y: -scale)
            ctx.cgContext.clip(to: CGRect(x: 0, y: 0, width: pageRect.width, height: pageRect.height - headerH))
            draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        bands.append(bodyImage)
        print("[SomaAI] PDF render halves (fallback): pageRect=\(Int(pageRect.width))x\(Int(pageRect.height))pt scale=\(scale) -> header [0..\(Int(headerH))pt] + body [\(Int(headerH))..\(Int(pageRect.height))pt] via CGContext clip")
        return bands
    }
}