import SwiftUI
import VisionKit

/// SwiftUI wrapper around `VNDocumentCameraViewController`. Apple's
/// native scanner does auto-crop, perspective correction and multi-page
/// capture for free. Replaces the bare UIImagePickerController which
/// had none of those.
///
/// 5d-scanner-fix: added onComplete callback. The previous design
/// used a `@Binding var scannedImages: [UIImage]` to ferry pages
/// back to AddLabTestView. That's the canonical SwiftUI bug:
/// when `parent.scannedImages = imgs` fires inside the delegate,
/// the sheet has already begun dismissing, so the binding write
/// silently no-ops and `.onChange(of: scannedPages)` never fires.
/// (The `ImagePicker` next to this has the same flaw but only for
/// single images, which still work by accident because UIImage
/// bindings survive dismissal — [UIImage] does not.) We now call
/// `onComplete(imgs)` synchronously from the delegate, which the
/// parent captures into a `Task` before the sheet tears down.
public struct DocumentScannerView: UIViewControllerRepresentable {
    var onComplete: ([UIImage]) -> Void = { _ in }
    var onError: (Error) -> Void = { _ in }
    var onCancel: () -> Void = {}

    public init(onComplete: @escaping ([UIImage]) -> Void = { _ in },
                onError: @escaping (Error) -> Void = { _ in },
                onCancel: @escaping () -> Void = {}) {
        self.onComplete = onComplete
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
            // 5d-scanner-fix: call onComplete synchronously here,
            // BEFORE the sheet dismisses. The parent assigns these
            // into its own @State right away and triggers the
            // pipeline. No @Binding round-trip through a closing
            // sheet.
            parent.onComplete(imgs)
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