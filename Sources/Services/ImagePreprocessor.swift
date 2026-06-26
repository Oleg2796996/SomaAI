import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Core Image pre-processor for medical documents. Runs BEFORE OCR
/// to lift text out of bad lighting, perspective skew and low contrast.
/// All operations are non-mutating; the original UIImage is preserved.
final class ImagePreprocessor {
    static let shared = ImagePreprocessor()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Auto-adjust exposure and contrast. First step in the OCR pipeline.
    func autoEnhance(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        var enhanced = ciImage

        // 1. Auto-adjust exposure / contrast / shadows / highlights.
        let auto = CIFilter.autoAdjustmentFilters()
        auto.inputImage = enhanced
        if let filters = auto.outputImage, let adjustments = auto.value(forKey: "filters") as? [CIFilter] {
            for f in adjustments { f.setValue(filters, forKey: kCIInputImageKey) }
            if let output = adjustments.last?.outputImage { enhanced = output }
        }

        // 2. Slight contrast boost on top (helps faded copies).
        let controls = CIFilter.colorControls()
        controls.inputImage = enhanced
        controls.contrast = 1.15
        controls.saturation = 0.9
        if let out = controls.outputImage { enhanced = out }

        return render(enhanced) ?? image
    }

    /// Grayscale + slight contrast bump. Fast pre-step for binarization.
    func grayscale(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.saturation = 0
        filter.contrast = 1.2
        return render(filter.outputImage) ?? image
    }

    /// Hard black/white. Used as a fallback when the main pass returns
    /// low confidence.
    func binarize(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let mono = CIFilter.colorMonochrome()
        mono.inputImage = ciImage
        mono.color = CIColor(red: 0.5, green: 0.5, blue: 0.5)
        mono.intensity = 1.0
        return render(mono.outputImage) ?? image
    }

    /// Manual contrast control. amount=1.0 leaves image unchanged.
    func applyContrast(_ image: UIImage, amount: Float) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter.colorControls()
        filter.inputImage = ciImage
        filter.contrast = amount
        return render(filter.outputImage) ?? image
    }

    /// Perspective correction. Pass 4 image-space points (topLeft,
    /// topRight, bottomLeft, bottomRight).
    func deskew(_ image: UIImage, corners: (CGPoint, CGPoint, CGPoint, CGPoint)) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = CIVector(cgPoint: corners.0)
        filter.topRight = CIVector(cgPoint: corners.1)
        filter.bottomLeft = CIVector(cgPoint: corners.2)
        filter.bottomRight = CIVector(cgPoint: corners.3)
        return render(filter.outputImage) ?? image
    }

    private func render(_ ciImage: CIImage?) -> UIImage? {
        guard let ciImage,
              let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}