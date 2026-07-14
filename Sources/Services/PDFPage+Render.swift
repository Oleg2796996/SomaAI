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
    /// split the resulting CGImage into a HEADER band (top 25%) and
    /// a BODY band (remaining 75%). The Vision call is then made
    /// twice per page — once for each band.
    ///
    /// Why header+body and not 50/50? Because the failure mode of
    /// the unsplit run (4.7ao-pdf-4) was that the HEADER was
    /// consistently dropped (OCR always started with "Показатель
    /// Результат Норма", never with the patient name, lab name or
    /// sample collection date). A 50/50 split (4.7ao-pdf-5a/5b) is
    /// too coarse — it wastes OCR budget on the middle of the page
    /// while still possibly clipping the date in the upper part of
    /// the top half. A targeted 25% header crop guarantees the date
    /// is in frame (and a 75% body crop is plenty for the marker
    /// table).
    ///
    /// CGImage.cropping is the Apple-blessed way to slice a rendered
    /// image. The crop rect's origin is top-left, Y growing down
    /// (UIKit convention — verified against Apple docs for
    /// CGImage.cropping(to:)). Header = y=0..headerH. Body =
    /// y=headerH..h.
    func renderAsImageHalves(scale: CGFloat = 3.0) -> [UIImage] {
        guard let fullImage = renderAsImage(scale: scale),
              let cgFull = fullImage.cgImage else {
            return renderAsImage(scale: scale).map { [$0] } ?? []
        }
        let w = cgFull.width
        let h = cgFull.height
        // 25% header. At 5360x7581 physical pixels this is 5360x1895
        // — wide enough to capture the full header line and the date
        // in a single Vision frame.
        let headerH = h / 4
        let bodyH = h - headerH
        var bands: [UIImage] = []
        // Header band: top 25% of the page
        let headerRect = CGRect(x: 0, y: 0, width: w, height: headerH)
        if let header = cgFull.cropping(to: headerRect) {
            bands.append(UIImage(cgImage: header, scale: 1.0, orientation: .up))
        }
        // Body band: bottom 75%
        let bodyRect = CGRect(x: 0, y: headerH, width: w, height: bodyH)
        if let body = cgFull.cropping(to: bodyRect) {
            bands.append(UIImage(cgImage: body, scale: 1.0, orientation: .up))
        }
        print("[SomaAI] PDF render halves: fullImage=\(w)x\(h)px (scale=\(scale)) -> header \(w)x\(headerH)px + body \(w)x\(bodyH)px via CGImage.cropping")
        return bands
    }
}