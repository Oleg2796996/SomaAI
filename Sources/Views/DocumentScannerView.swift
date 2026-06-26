import SwiftUI
import VisionKit

/// SwiftUI wrapper around `VNDocumentCameraViewController`. Apple's
/// native scanner does auto-crop, perspective correction and multi-page
/// capture for free. Replaces the bare UIImagePickerController which
/// had none of those.
///
/// `UIViewControllerRepresentable` protocol methods are public, so
/// the wrapping struct + its `Coordinator` must be public too. All
/// inherited public requirements are marked `public` explicitly here.
public struct DocumentScannerView: UIViewControllerRepresentable {
    @Binding var scannedImages: [UIImage]
    var onError: (Error) -> Void = { _ in }
    var onCancel: () -> Void = {}

    public init(scannedImages: Binding<[UIImage]>,
                onError: @escaping (Error) -> Void = { _ in },
                onCancel: @escaping () -> Void = {}) {
        self._scannedImages = scannedImages
        self.onError = onError
        self.onCancel = onCancel
    }

    public func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    public func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        public init(_ parent: DocumentScannerView) { self.parent = parent }

        public func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                 didFinishWith scan: VNDocumentCameraScan) {
            var imgs: [UIImage] = []
            for i in 0..<scan.pageCount {
                imgs.append(scan.imageOfPage(at: i))
            }
            parent.scannedImages = imgs
        }

        public func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        public func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                                 didFailWithError error: Error) {
            parent.onError(error)
        }
    }
}