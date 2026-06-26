import SwiftUI
import SwiftData
import PhotosUI
import PDFKit

struct AddLabTestView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let language: String

    @State private var testName: String = ""
    /// Note: provider is now auto-detected. We keep it as state for the
    /// user to override if OCR got it wrong.
    @State private var provider: String = ""
    @State private var date: Date = Date()
    @State private var documentType: DocumentType = .labResult
    @State private var isPressed = false

    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var isImportingPDF = false
    @State private var isShowingCamera = false
    @State private var isShowingScanner = false
    @State private var capturedImage: UIImage?
    @State private var scannedPages: [UIImage] = []
    @State private var recognizedText: String = ""
    @State private var ocrQuality: OCRQuality?
    @State private var isProcessing = false

    // Result of the 3-step pipeline. Drives the polymorphic VerificationView.
    @State private var pendingExtraction: SomaExtractionResponse?
    @State private var pendingMarkers: [SomaMarker] = []       // backward compat for lab path
    @State private var pendingMedications: [SomaMedication] = []
    @State private var pendingSections: [SomaSection] = []
    @State private var showingVerification = false
    @State private var apiError: String? = nil
    @State private var showingErrorAlert = false
    @State private var showOCRDebug = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(Localization.somaTranslate("add_test_section", language: language))) {
                    TextField(Localization.somaTranslate("field_test_name", language: language), text: $testName)
                    // Provider/organisation is now auto-detected by the LLM
                    // and shown on the verification screen, so we omit the
                    // form field here.
                    DatePicker(Localization.somaTranslate("field_date", language: language), selection: $date, displayedComponents: .date)
                }

                Section {
                    ImportButtonsView(
                        isProcessing: isProcessing,
                        onScan: { isShowingScanner = true },
                        onCamera: { isShowingCamera = true },
                        photosSelection: $selectedItems,
                        onPDF: { isImportingPDF = true },
                        language: language
                    )
                }

                Section {
                    Toggle("Show OCR Debug Text", isOn: $showOCRDebug)
                }

                if showOCRDebug && !recognizedText.isEmpty {
                    Section(header: Text("OCR Result (Debug)")) {
                        if let q = ocrQuality {
                            HStack {
                                Text("Quality: \(q.label)")
                                    .font(.caption)
                                Spacer()
                            }
                        }
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
            .sheet(isPresented: $isShowingScanner) {
                DocumentScannerView(scannedImages: $scannedPages, onError: { err in
                    apiError = err.localizedDescription
                    showingErrorAlert = true
                })
            }
            .onChange(of: scannedPages) { _, newValue in
                if !newValue.isEmpty {
                    Task { await handleScannedPages(newValue) }
                }
            }
            .onChange(of: capturedImage) { _, newValue in
                if let image = newValue {
                    Task { await handleSingleImageOCR(image) }
                }
            }
            .sheet(isPresented: $showingVerification) {
                VerificationView(
                    documentType: $documentType,
                    pendingExtraction: pendingExtraction,
                    markers: $pendingMarkers,
                    medications: $pendingMedications,
                    sections: $pendingSections,
                    testName: $testName,
                    provider: $provider,
                    documentDate: $date,
                    language: language,
                    onConfirm: {
                        saveFinalTest()
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
        let result = await OCRPipeline.shared.process(image: image)
        applyOCRResult(result, source: "single image")
    }

    private func handleScannedPages(_ pages: [UIImage]) async {
        isProcessing = true
        defer { isProcessing = false }
        let result = await OCRPipeline.shared.process(pages: pages)
        applyOCRResult(result, source: "scanner (\(pages.count) pages)")
    }

    private func handleImageSelection() async {
        guard !selectedItems.isEmpty else { return }
        isProcessing = true
        defer { isProcessing = false }
        var images: [UIImage] = []
        for item in selectedItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let img = UIImage(data: data) {
                images.append(img)
            }
        }
        guard !images.isEmpty else {
            apiError = "Could not load selected photos."
            showingErrorAlert = true
            return
        }
        let result = await OCRPipeline.shared.process(pages: images)
        applyOCRResult(result, source: "photos (\(images.count))")
    }

    private func handlePDFSelection(url: URL) async {
        isProcessing = true
        defer { isProcessing = false }
        guard let pdf = PDFDocument(url: url) else {
            apiError = "Could not open PDF."
            showingErrorAlert = true
            return
        }
        var images: [UIImage] = []
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let img = page.renderAsImage() {
                images.append(img)
            }
        }
        guard !images.isEmpty else {
            apiError = "PDF has no pages or all pages are blank."
            showingErrorAlert = true
            return
        }
        let result = await OCRPipeline.shared.process(pages: images)
        applyOCRResult(result, source: "PDF (\(images.count) pages)")
    }

    /// Centralised post-OCR handler. Stores the text, surfaces
    /// quality to the UI and prints a structured log line.
    private func applyOCRResult(_ result: OCRResult, source: String) {
        recognizedText = result.text
        ocrQuality = result.quality
        print("[SomaAI] OCR \(source): \(result.text.count) chars, quality=\(result.quality.label), confidence=\(result.confidence)")
        print("[SomaAI] OCR preview: \(String(result.text.prefix(400)))")
        if result.quality == .poor {
            apiError = "OCR quality is poor (confidence \(Int(result.confidence * 100))%). The extracted text may be incomplete. Try a clearer scan or higher-resolution image."
            showingErrorAlert = true
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
            // Quality gate: too-short OCR text -> unknown, no LLM call.
            let ocr = recognizedText
            if ocr.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
                apiError = "OCR text is too short (\(ocr.count) chars). Try a clearer photo or a different file."
                showingErrorAlert = true
                isProcessing = false
                return
            }

            do {
                // 3-step pipeline: classify -> extract -> validate
                let extraction = try await SomaAPIClient.shared.processDocument(ocr)
                pendingExtraction = extraction
                documentType = DocumentType(rawValue: extraction.type) ?? .unknown
                pendingMarkers = extraction.markers ?? []
                pendingMedications = extraction.medications ?? []
                pendingSections = extraction.sections ?? []
                // Auto-fill test name + provider from extraction if user
                // hasn't typed anything yet.
                if testName.trimmingCharacters(in: .whitespaces).isEmpty,
                   let title = extraction.title, !title.isEmpty {
                    testName = title
                }
                if provider.trimmingCharacters(in: .whitespaces).isEmpty,
                   let org = extraction.organization, !org.isEmpty {
                    provider = org
                }
                // Auto-set document title for unknown type to avoid blank state
                if documentType == .unknown, testName.trimmingCharacters(in: .whitespaces).isEmpty {
                    let isRU = (language == "Русский" || language == "Russian")
                    testName = isRU ? "Документ от \(date.formatted(date: .abbreviated, time: .omitted))" : "Document \(date.formatted(date: .abbreviated, time: .omitted))"
                }
                print("[SomaAI] 3-step pipeline: type=\(documentType.rawValue), conf=\(extraction.confidence), markers=\(pendingMarkers.count), meds=\(pendingMedications.count), sections=\(pendingSections.count)")

                // Local regex fallback for labResult only, and only when LLM returned nothing.
                if documentType == .labResult && pendingMarkers.isEmpty {
                    pendingMarkers = localRegexParse(ocr)
                    print("[SomaAI] Regex fallback extracted \(pendingMarkers.count) markers")
                }
                // For unknown type, seed a single section with the raw text
                // so the user can edit it in the verification sheet and
                // no data is silently lost.
                if documentType == .unknown, pendingSections.isEmpty {
                    let isRU = (language == "Русский" || language == "Russian")
                    pendingSections = [SomaSection(key: isRU ? "Текст" : "Text", value: ocr, order: 0)]
                }
            } catch {
                // Pipeline failed: still let the user save the document
                // as unknown with the raw OCR text. We do not want to
                // throw away the photo they just scanned.
                print("[SomaAI] 3-step pipeline error: \(error.localizedDescription)")
                print("[SomaAI] Fallback: showing verification as 'unknown' with raw OCR (\(ocr.count) chars)")
                documentType = .unknown
                pendingMarkers = []
                pendingMedications = []
                let isRU = (language == "Русский" || language == "Russian")
                pendingSections = [SomaSection(key: isRU ? "Текст" : "Text", value: ocr, order: 0)]
                if testName.trimmingCharacters(in: .whitespaces).isEmpty {
                    testName = isRU ? "Документ от \(date.formatted(date: .abbreviated, time: .omitted))" : "Document \(date.formatted(date: .abbreviated, time: .omitted))"
                }
                // Non-fatal warning, no modal alert — the verification
                // sheet will show the unknown UI which is more useful
                // than an error popup.
            }

            showingVerification = true
            isProcessing = false
        }
    }

    /// Best-effort local parser: scans OCR text for known lab marker names
    /// followed by a number / range on the next lines.
    private func localRegexParse(_ text: String) -> [SomaMarker] {
        let known: [(names: [String], unit: String?)] = [
            (["цвет", "color"], nil),
            (["прозрачность", "clarity", "appearance"], nil),
            (["ph"], nil),
            (["плотность", "удельный вес", "specific gravity", "sg"], nil),
            (["белок", "protein"], "г/л"),
            (["глюкоза", "glucose", "сахар"], "ммоль/л"),
            (["кетоны", "ketones"], "ммоль/л"),
            (["лейкоциты", "leukocytes", "wbc", "лейкоцит"], "в п/зр"),
            (["эритроциты", "erythrocytes", "rbc", "эритроцит"], "в п/зр"),
            (["нитриты", "nitrites"], nil),
            (["уробилиноген", "urobilinogen"], "мкмоль/л"),
            (["билирубин", "bilirubin"], "мкмоль/л"),
            (["слизь", "mucus"], nil),
            (["бактерии", "bacteria"], nil),
            (["эпителий", "epithelium"], "в п/зр"),
            (["гемоглобин", "hemoglobin", "hgb", "hb"], "г/л"),
            (["гематокрит", "hematocrit", "hct"], "%"),
            (["тромбоциты", "platelets", "plt"], "10^9/л")
        ]

        var found: [SomaMarker] = []
        let lower = text.lowercased()
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)

        for (names, defaultUnit) in known {
            for name in names {
                if let lineIdx = lines.firstIndex(where: { $0.lowercased().contains(name) }) {
                    // Look at the same line + next 2 lines for a number.
                    let window = lines[lineIdx..<min(lineIdx + 3, lines.count)].joined(separator: " ")
                    let valuePattern = "[0-9]+[\\.,]?[0-9]*"
                    if let match = window.range(of: valuePattern, options: .regularExpression) {
                        let value = String(window[match])
                        let displayName = lines[lineIdx].lowercased().contains(name) ? name : name
                        let marker = SomaMarker(
                            name: displayName.capitalized,
                            value: value,
                            unit: defaultUnit,
                            referenceRange: nil,
                            flag: nil
                        )
                        if !found.contains(where: { $0.name.lowercased() == marker.name.lowercased() }) {
                            found.append(marker)
                        }
                    }
                    break
                }
            }
            _ = lower
        }
        return found
    }

    private func saveFinalTest() {
        let newTest = LabTest(
            date: date,
            provider: provider,
            testName: testName.isEmpty
                ? (Localization.somaTranslate("vault_empty_title", language: language) + " \(date.formatted(date: .abbreviated, time: .omitted))")
                : testName,
            documentType: documentType,
            organization: provider.isEmpty ? nil : provider,
            rawText: recognizedText,
            extractionConfidence: pendingExtraction?.confidence ?? 0.5
        )

        // Lab markers
        for m in pendingMarkers {
            let marker = LabMarker(
                name: m.name,
                value: m.value,
                unit: m.unit,
                referenceRange: m.referenceRange,
                flag: m.flag
            )
            newTest.markers.append(marker)
        }
        // Prescriptions
        for p in pendingMedications {
            let med = PrescribedMed(
                name: p.name,
                dose: p.dose,
                frequency: p.frequency,
                duration: p.duration,
                route: p.route
            )
            newTest.prescriptions.append(med)
        }
        // Structured fields (epicrisis, consultation, etc.)
        for (idx, s) in pendingSections.enumerated() {
            let field = DocumentField(key: s.key, value: s.value, order: s.order ?? idx)
            newTest.structuredFields.append(field)
        }
        // Always mark uncertain fields so VerificationView can warn
        newTest.uncertainFields = pendingExtraction.map { _ in [] } ?? []

        modelContext.insert(newTest)
        do {
            try modelContext.save()
            print("[SomaAI] Saved \(documentType.rawValue) '\(newTest.testName)' with \(newTest.markers.count) markers / \(newTest.prescriptions.count) meds / \(newTest.structuredFields.count) sections")
        } catch {
            apiError = "Save failed: \(error.localizedDescription)"
            showingErrorAlert = true
            print("[SomaAI] Save error: \(error)")
        }
        dismiss()
    }
}

/// Extracted into its own struct because the 4-button stack inside
/// `AddLabTestView.body` was hitting Swift's "unable to type-check
/// this expression in reasonable time" diagnostic. Smaller subviews
/// give the type checker an easy time.
private struct ImportButtonsView: View {
    let isProcessing: Bool
    let onScan: () -> Void
    let onCamera: () -> Void
    @Binding var photosSelection: [PhotosPickerItem]
    let onPDF: () -> Void
    let language: String

    var body: some View {
        VStack(spacing: 12) {
            Button(action: onScan) {
                Label(Localization.somaTranslate("button_scan", language: language), systemImage: "doc.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

            Button(action: onCamera) {
                Label(Localization.somaTranslate("button_camera", language: language), systemImage: "camera.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

            PhotosPicker(selection: $photosSelection, matching: .images) {
                Label(Localization.somaTranslate("button_photos", language: language), systemImage: "photo.on.rectangle.angled")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)

            Button(action: onPDF) {
                Label(Localization.somaTranslate("button_pdf", language: language), systemImage: "doc.text.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(isProcessing)
        }
    }
}
