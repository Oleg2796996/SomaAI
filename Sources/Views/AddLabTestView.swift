import SwiftUI
import SwiftData
import PhotosUI
import Vision
import PDFKit

struct AddLabTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let language: String

    @State private var testName: String = ""
    @State private var provider: String = ""
    @State private var date: Date = Date()
    @State private var isPressed = false

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isImportingPDF = false
    @State private var isShowingCamera = false
    @State private var capturedImage: UIImage?
    @State private var recognizedText: String = ""
    @State private var isProcessing = false

    @State private var showingVerification = false
    @State private var pendingMarkers: [SomaMarker] = []
    @State private var apiError: String? = nil
    @State private var showingErrorAlert = false
    @State private var showOCRDebug = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(Localization.somaTranslate("add_test_section", language: language))) {
                    TextField(Localization.somaTranslate("field_test_name", language: language), text: $testName)
                    TextField(Localization.somaTranslate("field_provider", language: language), text: $provider)
                    DatePicker(Localization.somaTranslate("field_date", language: language), selection: $date, displayedComponents: .date)
                }

                Section {
                    VStack(spacing: 12) {
                        Button(action: { isShowingCamera = true }) {
                            Label(Localization.somaTranslate("button_camera", language: language), systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)

                        PhotosPicker(selection: $selectedItems, matching: .images) {
                            Label(Localization.somaTranslate("button_photos", language: language), systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)

                        Button(action: { isImportingPDF = true }) {
                            Label(Localization.somaTranslate("button_pdf", language: language), systemImage: "doc.text.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                    }
                }

                Section {
                    Toggle("Show OCR Debug Text", isOn: $showOCRDebug)
                }

                if showOCRDebug && !recognizedText.isEmpty {
                    Section(header: Text("OCR Result (Debug)")) {
                        ScrollView {
                            Text(recognizedText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 150)
                    }
                }

                Section {
                    Button(action: processAndVerify) {
                        if isProcessing {
                            ProgressView().progressViewStyle(.circular)
                        } else {
                            Text(Localization.somaTranslate("button_save", language: language))
                                .frame(maxWidth: .infinity)
                                .fontWeight(.bold)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isProcessing || recognizedText.isEmpty)
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.spring(), value: isPressed)
                }

                Section {
                    Text(Localization.somaTranslate("disclaimer_data_only", language: language))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(Localization.somaTranslate("add_test_title", language: language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedItems) { _, _ in
                Task { await handleImageSelection() }
            }
            .fileImporter(
                isPresented: $isImportingPDF,
                allowedContentTypes: [.pdf],
                onCompletion: { result in
                    switch result {
                    case .success(let url):
                        Task { await handlePDFSelection(url: url) }
                    case .failure(let error):
                        print("PDF Error: \(error)")
                    }
                }
            )
            .sheet(isPresented: $isShowingCamera) {
                ImagePicker(image: $capturedImage)
            }
            .onChange(of: capturedImage) { _, newValue in
                if let image = newValue {
                    Task { await handleSingleImageOCR(image) }
                }
            }
            .sheet(isPresented: $showingVerification) {
                VerificationView(
                    markers: $pendingMarkers,
                    language: language,
                    onConfirm: { confirmedMarkers in
                        saveFinalTest(with: confirmedMarkers)
                    }
                )
            }
            .alert("Analysis Error", isPresented: $showingErrorAlert, presenting: apiError) { _ in
                Button("OK") {}
            } message: { error in
                Text(error)
            }
        }
    }

    private func handleSingleImageOCR(_ image: UIImage) async {
        isProcessing = true
        defer { isProcessing = false }
        do {
            let text = try await performOCR(on: image)
            recognizedText = text
        } catch {
            apiError = "OCR failed: \(error.localizedDescription)"
            showingErrorAlert = true
        }
    }

    private func handleImageSelection() async {
        guard !selectedItems.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }
        var allText = ""

        await withTaskGroup(of: (Int, String).self) { group in
            for (index, item) in selectedItems.enumerated() {
                group.addTask {
                    do {
                        if let data = try await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            let text = try await self.performOCR(on: image)
                            return (index, text)
                        }
                    } catch {
                        print("OCR Error on page \(index): \(error)")
                    }
                    return (index, "")
                }
            }

            var results = [Int: String]()
            for await (index, text) in group {
                results[index] = text
            }

            allText = results.sorted(by: { $0.key < $1.key })
                             .map { "--- Page \($0.key + 1) ---\n\($0.value)" }
                             .joined(separator: "\n\n")
        }

        recognizedText = allText
    }

    private func handlePDFSelection(url: URL) async {
        isProcessing = true
        defer { isProcessing = false }
        var allText = ""

        do {
            if let pdf = PDFDocument(url: url) {
                let pageCount = pdf.pageCount
                var images = [UIImage]()

                for i in 0..<pageCount {
                    if let page = pdf.page(at: i) {
                        let bounds = page.bounds(for: .mediaBox)
                        let pageSize = CGSize(width: bounds.width, height: bounds.height)
                        let img = page.thumbnail(of: pageSize, for: .mediaBox)
                        images.append(img)
                    }
                }

                var pageResults = [Int: String]()
                await withTaskGroup(of: (Int, String).self) { group in
                    for (index, image) in images.enumerated() {
                        group.addTask {
                            do {
                                let text = try await self.performOCR(on: image)
                                return (index, text)
                            } catch {
                                return (index, "")
                            }
                        }
                    }
                    for await (index, text) in group {
                        pageResults[index] = text
                    }
                }

                allText = pageResults.sorted(by: { $0.key < $1.key })
                                     .map { "--- PDF Page \($0.key + 1) ---\n\($0.value)" }
                                     .joined(separator: "\n\n")
            }
        } catch {
            apiError = "PDF processing failed: \(error.localizedDescription)"
            showingErrorAlert = true
        }

        recognizedText = allText
    }

    private func performOCR(on image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCR", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to get CGImage"])
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = request.results as? [VNRecognizedTextObservation]
                let recognizedStrings = observations?.compactMap { $0.topCandidates(1).first?.string } ?? []
                let fullText = recognizedStrings.joined(separator: "\n")
                continuation.resume(returning: fullText)
            }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func processAndVerify() {
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isPressed = false
        }

        guard !recognizedText.isEmpty else { return }

        isProcessing = true
        Task {
            do {
                let markers = try await SomaAPIClient.shared.structureText(recognizedText)
                pendingMarkers = markers
                showingVerification = true
            } catch {
                apiError = error.localizedDescription
                showingErrorAlert = true
            }
            isProcessing = false
        }
    }

    private func saveFinalTest(with markers: [SomaMarker]) {
        let newTest = LabTest(date: date, provider: provider, testName: testName)

        for m in markers {
            let marker = LabMarker(
                name: m.name,
                value: m.value,
                unit: m.unit,
                referenceRange: m.referenceRange,
                flag: m.flag
            )
            newTest.markers.append(marker)
        }

        modelContext.insert(newTest)
        do {
            try modelContext.save()
            print("[SomaAI] Saved LabTest '\(newTest.testName)' with \(newTest.markers.count) markers")
        } catch {
            apiError = "Save failed: \(error.localizedDescription)"
            showingErrorAlert = true
            print("[SomaAI] Save error: \(error)")
        }
        dismiss()
    }
}
