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
    /// Sprint 4.7ao-pdf-5d-fifth: 35% still missed it. The 15:26
    /// build's OCR preview starts with "Неорганиз. осадок мочи
    /// (соли)" — body table data, NOT the patient block. The date
    /// must sit around 40-50% of the page, not 25-30%. Bumped
    /// to 50% (header 5360x3790, body 5360x3790). 50/50 was
    /// tested in 4.7ao-pdf-5a/5b but with the WRONG split method
    /// (draw(with:to:) squished, CGImage.cropping hadn't been
    /// tried at 50/50). With the proven CGImage.cropping path,
    /// 50/50 should be safe.
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
        // Sprint 4.7ao-pdf-5d-fifth: header 35% -> 50%. Oleg's
        // 15:26 log (first successful build after 5e-bis fix) shows
        // that the OCR text from the 35% header band starts with
        // "Неорганиз. осадок мочи (соли)" — table data, NOT
        // patient name / lab name / sample date. The header band
        // on НКЦ2 lab PDFs is therefore MORE than 35% of the page
        // — probably the date sits in the upper-middle (40-50%),
        // not in the top quarter. Bump to 50% so we capture both
        // the patient block AND the start of the table. The body
        // band shrinks from 65% to 50% (≈3789px on 7581px page)
        // — still plenty for the 24-marker table.
        let headerH = Int(Double(h) * 0.50)
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
        print("[SomaAI] PDF render halves: fullImage=\(w)x\(h)px (scale=\(scale)) -> header \(w)x\(headerH)px (50%) + body \(w)x\(bodyH)px (50%) via CGImage.cropping")
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

    /// Sprint 4.7ao-pdf-5d-sixth: render JUST the top 15% of the page
    /// at scale=4.0 (12x physical on Retina). Why a third pass?
    ///
    /// The 15:36 log (Oleg ran 4.7ao-pdf-5d-fifth with header 50% +
    /// body 50%) shows that the 50% header band STILL doesn't
    /// contain the patient block. The OCR text from that band
    /// starts with "Неорганиз. осадок мочи (соли)" — body table
    /// data, not patient name or sample date.
    ///
    /// The patient block (ФИО, лаборатория, дата забора "07.11.2025")
    /// on НКЦ2 lab PDFs is in the very top of the page — clinic
    /// name ~5%, patient block ~10-12%. The previous header
    /// bands (25%, 35%, 50%) were all WIDE-AND-LOW res (scale=3.0
    /// over half the page = 3790px tall for the date in 12% of
    /// the page = 900px actual). The date in those renders is
    /// 7-8pt font × 216 DPI = 17-19 pixels tall, which Vision
    /// sometimes drops on the iOS 26.5 simulator.
    ///
    /// The 5d-sixth pass renders ONLY the top 15% (842pt * 0.15 =
    /// 126pt = 504pt cropped) at scale=4.0 (12x physical), giving
    /// 126pt * 4.0 * 3 (Retina) = 1512px tall and 595pt * 12 =
    /// 7140px wide. Date text at 7-8pt × 4.0 × 3 = 84-96px tall —
    /// comfortably readable by Vision.
    ///
    /// Cost: 1 extra Vision call per page. For a 2-page PDF this
    /// is 2 extra calls (was 4, now 6). Pipeline fits inside 75s.
    ///
    /// Sprint 4.7ao-pdf-5d-sixth-bis: switched from CGContext.clip
    /// to CGImage.cropping. The 5d-sixth attempt used
    /// UIGraphicsImageRenderer's CGContext.clip(to:) — but
    /// UIGraphicsImageRenderer always produces a full-canvas
    /// UIImage regardless of clip. Oleg's 15:55 log showed
    /// `cgImage=7146x10107px` (the FULL page) instead of the
    /// expected 7146x1512px cropped strip. Vision's effective
    /// ceiling on iOS 26.5 is ~5000-7000px on the long side —
    /// 10107px is OVER the ceiling, so Vision OCR returned empty
    /// text. CGImage.cropping(to:) is the proven path (used by
    /// 5d/5d-ter/5d-fifth) and gives a properly-sized UIImage.
    func renderAsImageTopStrip(stripRatio: CGFloat = 0.15, scale: CGFloat = 4.0) -> [UIImage] {
        // Sprint 4.7ao-pdf-5d-sixth-bis: delegate to renderAsImage
        // at the requested scale, then CGImage.cropping the top
        // stripRatio. This matches the proven halves path.
        guard let fullImage = renderAsImage(scale: scale),
              let cgFull = fullImage.cgImage else {
            // If full render or cropping failed (iOS 26.5 sim
            // sometimes returns nil cgImage for big renders), skip
            // the top-strip pass and return an empty array so
            // handlePDFSelection doesn't get a bad image. The
            // halves pass still runs.
            print("[SomaAI] PDF render top-strip: FAILED (no cgImage), skipping")
            return []
        }
        let w = cgFull.width
        let h = cgFull.height
        let stripH = Int(Double(h) * stripRatio)
        // CGImage.cropping(to:) uses top-left origin with Y growing
        // down (UIKit convention). Top of the page = y=0. The PDF
        // renderAsImage already returned the page with text
        // right-side up (Y-flipped), so y=0 IS the top.
        let topRect = CGRect(x: 0, y: 0, width: w, height: stripH)
        guard let cgTop = cgFull.cropping(to: topRect) else {
            print("[SomaAI] PDF render top-strip: cropping failed for \(w)x\(stripH)px, skipping")
            return []
        }
        let topImage = UIImage(cgImage: cgTop, scale: 1.0, orientation: .up)
        print("[SomaAI] PDF render top-strip: pageRect=\(Int(w))x\(Int(h))px (scale=\(scale)) -> top strip \(cgTop.width)x\(cgTop.height)px (stripRatio=\(stripRatio)) via CGImage.cropping")
        return [topImage]
    }
}