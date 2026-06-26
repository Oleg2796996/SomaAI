import UIKit
import PDFKit

extension PDFPage {
    /// Render a PDF page to UIImage at the given scale (3.0 is retina
    /// sharp; 1.0 reproduces the legacy `PDFPage.thumbnail(of:for:)`
    /// behaviour but at lower quality). The default of 3.0 keeps small
    /// print legible to the OCR engine.
    func renderAsImage(scale: CGFloat = 3.0) -> UIImage? {
        let pageRect = bounds(for: .mediaBox)
        let pixelSize = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        let renderer = UIGraphicsImageRenderer(size: pixelSize)
        return renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: pixelSize))
            ctx.cgContext.saveGState()
            ctx.cgContext.scaleBy(x: scale, y: scale)
            draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
    }
}