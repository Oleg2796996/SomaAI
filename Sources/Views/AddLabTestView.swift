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
    // Sprint 4.7ao-pdf-5g: true once `date` has been set from OCR
    // extraction (LLM returned a non-today date) or from the
    // LocalExtractor.scan fallback. Drives the small "⏳ will be
    // detected after processing" hint under the DatePicker so the
    // user understands that the date they see right after file
    // selection is just a default — it's NOT the actual sample date
    // until they tap Process.
    @State private var dateIsFromExtraction: Bool = false
    // Sprint 4.7ao-pdf-5d-tenth: date extracted DIRECTLY from the
    // PDF's native text (via PDFKit.PDFDocument.string) without
    // Vision OCR. The 16:41 pymupdf analysis of the бланк НКЦ2
    // моча PDF showed the date '07.11.2025 10:59' lives in real
    // selectable text at Y=15.7% — not an image. PDFKit exposes
    // this via `.string` and extractBestDate's Strategy 0
    // ("доставка биоматериала" added in 5e-quarter) finds it.
    // If non-nil, we override any OCR-derived date in
    // processAndVerify.
    @State private var pdfNativeDate: String?
    // Sprint 4.7ao-pdf-5d-eleventh: markers extracted directly
    // from PDFKit.PDFDocument.string via PDFNativeParser.
    // When non-nil with count >= 5, processAndVerify uses these
    // markers instead of calling Vision OCR + the LLM. Avoids
    // the 4-call × ~20s = 80s pipeline that exceeded the 75s
    // processDocument timeout in 5d-tenth (e500c6a).
    @State private var pdfNativeMarkers: [PDFNativeParser.PDFMarker]?

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
                    // Sprint 4.7ao-pdf-5g: small caption that clarifies
                    // whether the displayed date is the default
                    // (today, until OCR runs) or a real value extracted
                    // from the document. Without this hint, the user
                    // sees today's date right after selecting a file
                    // and assumes OCR misread the sample date.
                    if !dateIsFromExtraction {
                        Text("⏳ Будет определена после обработки (сейчас — сегодня)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        Text("✅ Определена из документа")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }
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
                // Sprint 4.7ai: allow .pdf plus the broader PDF/data UTI
                // set so AirDrop-received PDFs (which sometimes lack the
                // public.pdf UTI) still appear in the picker.
                allowedContentTypes: [.pdf, .data, .item],
                onCompletion: { result in
                    switch result {
                    case .success(let url):
                        print("[SomaAI] fileImporter picked url=\(url.lastPathComponent) pathExt=\(url.pathExtension)")
                        Task { await handlePDFSelection(url: url) }
                    case .failure(let error):
                        print("[SomaAI] fileImporter Error: \(error.localizedDescription)")
                    }
                }
            )
            .sheet(isPresented: $isShowingCamera) {
                ImagePicker(image: $capturedImage)
            }
            .sheet(isPresented: $isShowingScanner) {
                DocumentScannerView(
                    onComplete: { imgs in
                        // 5d-scanner-fix: capture images synchronously
                        // here, BEFORE the sheet dismisses. The previous
                        // @Binding-based design lost pages because the
                        // sheet tears down before the binding write
                        // propagates. We assign into @State directly and
                        // kick off the same pipeline as .onChange did.
                        scannedPages = imgs
                        isShowingScanner = false
                        Task { await handleScannedPages(imgs) }
                    },
                    onError: { err in
                        apiError = err.localizedDescription
                        showingErrorAlert = true
                        isShowingScanner = false
                    }
                )
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
        // Sprint 4.7r: table-aware OCR auto-enabled for labResult documents.
        // The user selects documentType before scanning (default: labResult),
        // and smartClassify's regex precheck confirms/refines it. For lab
        // panels, Vision Framework loses the column structure on the
        // "Result" column without bounding-box aware grouping.
        let useTable = (documentType == .labResult) || Self.tableModeEnabled
        print("[SomaAI] tableMode=" + useTable.description + " docType=" + documentType.rawValue)
        let result = await OCRPipeline.shared.process(image: image, useTableMode: useTable)
        applyOCRResult(result, source: "single image")
    }

    private func handleScannedPages(_ pages: [UIImage]) async {
        isProcessing = true
        defer { isProcessing = false }
        let useTable = (documentType == .labResult) || Self.tableModeEnabled
        print("[SomaAI] tableMode=" + useTable.description + " docType=" + documentType.rawValue)
        let result = await OCRPipeline.shared.process(pages: pages, useTableMode: useTable)
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
        let useTable = (documentType == .labResult) || Self.tableModeEnabled
        print("[SomaAI] tableMode=" + useTable.description + " docType=" + documentType.rawValue)
        let result = await OCRPipeline.shared.process(pages: images, useTableMode: useTable)
        applyOCRResult(result, source: "photos (\(images.count))")
    }

    private func handlePDFSelection(url: URL) async {
        isProcessing = true
        defer { isProcessing = false }
        // Sprint 4.7ai: iOS 14+ requires explicit security-scoped resource
        // access for files returned by fileImporter/UIDocumentPicker.
        // Without this, PDFDocument(url:) silently returns nil →
        // "Could not open PDF" alert with no actionable log.
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        print("[SomaAI] handlePDFSelection url=\(url.lastPathComponent) pathExt=\(url.pathExtension) scope=\(didStart)")
        // Sprint 4.7ao-pdf-5d-tenth: extract the PDF's text content
        // DIRECTLY via PDFKit (bypassing Vision OCR). The 16:41
        // log of the бланк НКЦ2 моча PDF coordinates (via
        // pymupdf on WSL) showed:
        //   Y=2.0%  "Научно-клинический центр №2"
        //   Y=3.4%  "ФГБНУ «РНЦХ им. акад. Б.В. Петровского»"
        //   Y=4.7%  "Клинико-диагностическая лаборатория"
        //   Y=6.6%  "г. Москва, Литовский б-р..."
        //   Y=10.2% "Ф.И.О.: КОНОВАЛОВ ОЛЕГ АЛЕКСАНДРОВИЧ"
        //   Y=11.6% "Дата рождения: 17.01.1981 (44 г.)   Пол: М"
        //   Y=13.0% "№ карты: 21847522"
        //   Y=14.3% "Биоматериал: Моча (разовая);"
        //   Y=15.7% "Доставка биоматериала: 07.11.2025 10:59"   <-- date here
        //   Y=20.1% "Физико-химические свойства"                 <-- table starts
        // Font is 9.9pt (not 7-8pt as we assumed). Top-strip
        // stripRatio 0.20 caught the body table header but
        // missed the date (Vision dropped the small 9.9pt text
        // at 15.7%). With 2 Vision calls, we either get the
        // table OR the patient block — never both reliably.
        //
        // The fix: USE THE PDF'S NATIVE TEXT (selectable, not
        // raster) for the date. pymupdf on WSL extracted
        // "07.11.2025 10:59" perfectly via get_text("dict") —
        // the text is real, not an image. PDFKit's PDFDocument
        // exposes the same text via `.string` and per-page
        // `.string`. extractBestDate has Strategy 0 (keyword
        // proximity, "доставка биоматериала" added in 5e-quarter)
        // which will pick "2025-11-07" from this clean text.
        //
        // Vision OCR is still used for MARKERS (the table body)
        // — PDFKit string includes numbers, but not always the
        // lab's exact formatting ("не обнаружено" vs "0", etc.).
        // Vision remains the source of truth for markers; native
        // PDF text is the source of truth for date/ФИО/лаб.
        guard let pdf = PDFDocument(url: url) else {
            print("[SomaAI] PDF Error: PDFDocument(url:) returned nil for \(url.lastPathComponent)")
            apiError = "Could not open PDF. The file may be encrypted, corrupted, or in an unsupported format."
            showingErrorAlert = true
            return
        }
        // 5d-tenth (continued): pdf is now valid, extract native text.
        let pdfNativeText = pdf.string ?? ""
        print("[SomaAI] PDF native text: \(pdfNativeText.count) chars (no Vision OCR)")
        if let pdfDate = LocalExtractor.extractBestDate(pdfNativeText), !pdfDate.isEmpty {
            print("[SomaAI] PDF native date extracted: \(pdfDate) (overrides OCR-based date)")
            self.pdfNativeDate = pdfDate
        } else {
            self.pdfNativeDate = nil
        }
        // Sprint 4.7ao-pdf-5d-eleventh: try to parse markers AND
        // patient info from the native PDFKit text. For digital
        // PDFs (the НКЦ2 бланк is one — pymupdf showed all 25
        // markers as selectable text), this bypasses Vision OCR
        // entirely. 4 Vision calls × ~20s = 80s > 75s
        // processDocument timeout, which is why 5d-tenth
        // (e500c6a) hit the timer and ended with markers=0.
        //
        // If the native parse gives >= 5 markers, we set
        // `self.pdfNativeMarkers` and skip the entire Vision OCR
        // + LLM extraction branch in processAndVerify. If < 5
        // markers (image-only PDF or layout we don't recognise),
        // we fall back to the Vision OCR pipeline.
        if let parsed = PDFNativeParser.parse(pdf: pdf), parsed.markers.count >= 5 {
            print("[SomaAI] PDF native MARKERS extracted: \(parsed.markers.count) (skipping Vision OCR entirely)")
            for (idx, m) in parsed.markers.prefix(5).enumerated() {
                print("[SomaAI]   native marker[\(idx)]: name='\(m.name)' value=\(m.value ?? "nil") unit=\(m.unit ?? "nil") range=\(m.referenceRange ?? "nil")")
            }
            self.pdfNativeMarkers = parsed.markers
            // Also auto-fill patient name + lab from the PDF if
            // the user hasn't typed anything yet.
            if testName.trimmingCharacters(in: .whitespaces).isEmpty,
               let name = parsed.patient.fullName, !name.isEmpty {
                testName = "Анализ от \(name)"
                print("[SomaAI] PDF native testName: \(testName)")
            }
            if provider.trimmingCharacters(in: .whitespaces).isEmpty,
               let lab = parsed.patient.laboratory, !lab.isEmpty {
                provider = lab
                print("[SomaAI] PDF native provider: \(provider)")
            }
        } else {
            self.pdfNativeMarkers = nil
            print("[SomaAI] PDF native parse yielded < 5 markers or no parse — will use Vision OCR fallback")
        }
        var images: [UIImage] = []
        // If we have enough native markers, skip rendering pages
        // entirely. This collapses 4 Vision calls to 0 and
        // avoids the 75s timeout (proven by 5d-tenth hitting
        // the timer with the same 4 calls).
        if self.pdfNativeMarkers?.count ?? 0 >= 5 {
            // Use a tiny dummy 1x1 image to satisfy the
            // !images.isEmpty guard, and to keep the rest of the
            // pipeline unchanged. Vision OCR is bypassed
            // because processAndVerify short-circuits when
            // `pdfNativeMarkers` is set.
            print("[SomaAI] Skipping PDF page rendering — using native markers directly")
        } else {
        for i in 0..<pdf.pageCount {
            // Sprint 4.7ao-pdf-5d: render each page as a HEADER band
            // (top 25%) + a BODY band (bottom 75%) via
            // CGImage.cropping(to:). The header is what carries the
            // patient name, lab name, sample date — Vision was
            // dropping this band on every prior un-split run.
            // The body is the marker table, which we know works at
            // full Retina 9x scale.
            // For a 2-page PDF this gives 4 Vision calls; the
            // pipeline is fast enough to fit inside the 75s
            // processDocument budget (proven by 4.7ao-pdf-4's
            // 2-call baseline).
            if let page = pdf.page(at: i) {
                // Sprint 4.7ao-pdf-5d-ninth: full rewrite of the
                // per-page Vision pipeline. The 4.7ao-pdf-5d-*
                // sprints tried multiple combinations of top-strip
                // (0.15, 0.30) + halves (50/50). All failed to
                // catch the patient block date '07.11.2025' on
                // НКЦ2 lab PDFs.
                //
                // The 16:28 photo Oleg sent of the patient block
                // shows the layout:
                //   Ф.И.О.: КОНОВАЛОВ ОЛЕГ АЛЕКСАНДРОВИЧ
                //   Дата рождения: 17.01.1981 (44 г.)   Пол: М
                //   № карты: 21847522
                //   Биоматериал: Моча (разовая);
                //   Доставка биоматериала: 07.11.2025 10:59
                //
                // Two-part fix this sprint:
                //
                // (A) Top-strip 0.20 at scale=5.0. Why 0.20?
                //   - 0.15 was too tight (OCR empty).
                //   - 0.30 catches body table ('Цилиндры
                //     гиалиновые' at 252pt).
                //   - 0.20 = 168pt — covers the patient block
                //     which sits between the lab header and the
                //     table.
                // Why scale=5.0 (15x physical)?
                //   - 4.0 gave 7-8pt text at 84-96 actual pixels
                //     which Vision sometimes drops.
                //   - 5.0 = 105-120 pixels per char — well above
                //     Vision's drop threshold.
                //   - 168pt × 5.0 × 3 (Retina) = 2520px tall,
                //     595pt × 5.0 × 3 = 8925px wide — still under
                //     Vision's ~10000px ceiling on iOS 26.5 sim.
                //
                // (B) Replaced halves with full-page render. The
                // 5d-fifth halves (50/50 split) gave conf 0.29
                // on the header and 10 markers from the body. The
                // 4.7ao-pdf-4 (full page, scale=3.0) gave conf
                // 0.87 and 8+ markers. Halves are an unnecessary
                // extra call that degrades conf. Use full page
                // instead — it's what worked in 4.7ao-pdf-4.
                //
                // Net effect: 2 calls per page (top-strip + full)
                // vs. 3 calls in 5d-seventh (top-strip + 2 halves).
                // For a 2-page PDF = 4 calls, comfortably under
                // 75s timeout.
                let topStrips = page.renderAsImageTopStrip(stripRatio: 0.20, scale: 5.0)
                images.append(contentsOf: topStrips)
                let fullImage = page.renderAsImage(scale: 3.0)
                if let img = fullImage {
                    images.append(img)
                }
            }
        }
        }  // close the else branch from 5d-eleventh (skip rendering when native markers are enough)
        // 5d-eleventh: if native markers were extracted from
        // PDFKit, short-circuit here — set recognizedText to
        // the native text and jump to processAndVerify which
        // will see pdfNativeMarkers and use them directly.
        if let native = self.pdfNativeMarkers, native.count >= 5 {
            print("[SomaAI] PDF native parse shortcut: \(native.count) markers, bypassing Vision OCR")
            // The native text is a much cleaner input to the
            // pipeline than Vision OCR's noisy transcription.
            recognizedText = pdfNativeText
            // Set isProcessing back so the Process button is
            // tappable again.
            isProcessing = false
            // Auto-trigger the verification flow.
            processAndVerify()
            return
        }
        guard !images.isEmpty else {
            apiError = "PDF has no pages or all pages are blank."
            showingErrorAlert = true
            return
        }
        let useTable = (documentType == .labResult) || Self.tableModeEnabled
        print("[SomaAI] tableMode=" + useTable.description + " docType=" + documentType.rawValue)
        // Sprint 4.7an: PDF renders are already clean black-on-white at 5x
        // scale, so pass isFromPDFRender=true to skip autoEnhance (which
        // would otherwise lower saturation and turn tables grey, causing
        // Vision OCR to drop most rows).
        let result = await OCRPipeline.shared.process(pages: images, useTableMode: useTable, isFromPDFRender: true)
        applyOCRResult(result, source: "PDF (\(images.count) pages)")
    }

    /// Sprint 4.7q: enable table-aware OCR (Sprint 4.7q) via launch
    /// argument `-SOMA_TABLE_MODE 1` or env `SOMA_TABLE_MODE=1`. Default
    /// OFF so existing users see no behaviour change. Once verified,
    /// we'll auto-enable for `labResult` documents after smartClassify
    /// has run.
    private static var tableModeEnabled: Bool {
        if let arg = UserDefaults.standard.string(forKey: "SOMA_TABLE_MODE"),
           ["1", "true", "yes"].contains(arg.lowercased()) { return true }
        if let env = ProcessInfo.processInfo.environment["SOMA_TABLE_MODE"],
           ["1", "true", "yes"].contains(env.lowercased()) { return true }
        return false
    }

    /// Centralised post-OCR handler. Stores the text, surfaces
    /// quality to the UI and prints a structured log line.
    private func applyOCRResult(_ result: OCRResult, source: String) {
        recognizedText = result.text
        ocrQuality = result.quality
        print("[SomaAI] OCR \(source): \(result.text.count) chars, quality=\(result.quality.label), confidence=\(result.confidence)")
        print("[SomaAI] OCR preview: \(String(result.text.prefix(400)))")
        // Sprint 4.7ao-pdf: for PDF renders, .medium quality is acceptable
        // (Vision on iOS 26.5 sim caps at ~56% confidence for Russian
        // text in clean PDF renders — but the data is still valid).
        // Only block on .poor, and only if it's NOT a PDF (photos
        // genuinely need better quality).
        let isPDF = source.hasPrefix("PDF")
        if result.quality == .poor && !isPDF {
            apiError = "OCR quality is poor (confidence \(Int(result.confidence * 100))%). The extracted text may be incomplete. Try a clearer scan or higher-resolution image."
            showingErrorAlert = true
        }

        // 5d-scan-regex-first: try native line-aware parser on the
        // OCR text. If the document has the standard lab table
        // headers (Физико-химические свойства / Микроскопическое
        // исследование осадка), we get markers WITHOUT calling
        // the LLM extractor — saving 5-10 seconds per scan.
        if !isPDF {
            if let parsed = PDFNativeParser.parse(text: result.text), parsed.markers.count >= 5 {
                print("[SomaAI] 5d-scan-regex-first: recovered \(parsed.markers.count) markers from OCR text (skipping LLM extract)")
                self.pdfNativeMarkers = parsed.markers
                if testName.trimmingCharacters(in: .whitespaces).isEmpty,
                   let name = parsed.patient.fullName, !name.isEmpty {
                    testName = "Анализ от \(name)"
                }
                if provider.trimmingCharacters(in: .whitespaces).isEmpty,
                   let lab = parsed.patient.laboratory, !lab.isEmpty {
                    provider = lab
                }
            } else {
                self.pdfNativeMarkers = nil
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
            // Quality gate: too-short OCR text -> unknown, no LLM call.
            let ocr = recognizedText
            // Sprint 4.7ao-pdf-5d-eleventh: short-circuit when we
            // have native PDFKit markers. The OCR text in this
            // branch is the CLEAN native text (set in
            // handlePDFSelection before processAndVerify() was
            // called), but we don't even need the LLM — we have
            // the markers already.
            if let native = pdfNativeMarkers, native.count >= 5 {
                print("[SomaAI] processAndVerify: using NATIVE markers (\(native.count)), skipping LLM")
                documentType = .labResult
                pendingMarkers = native.map { m in
                    SomaMarker(
                        name: m.name,
                        value: m.value ?? "—",
                        unit: m.unit,
                        referenceRange: m.referenceRange,
                        flag: SomaAPIClient.computeFlag(value: m.value ?? "—", reference: m.referenceRange)
                    )
                }
                pendingMedications = []
                pendingSections = []
                if testName.trimmingCharacters(in: .whitespaces).isEmpty {
                    testName = "Анализ — НКЦ2"
                }
                // 5d-twenty-second: set date from pdfNativeDate
                // in the short-circuit branch. The non-short-
                // circuit branch already does this (line ~556 in
                // the OCR/LLM path) but native marker shortcut
                // was returning before assigning self.date, so
                // the verification sheet showed today's date.
                var dateFromExtraction = false
                if let pdfDate = pdfNativeDate, let parsed = Self.parseExtractionDate(pdfDate) {
                    date = parsed
                    dateFromExtraction = true
                    print("[SomaAI] document date set from PDF NATIVE text (shortcut): \(parsed) (overriding today)")
                }
                self.dateIsFromExtraction = dateFromExtraction
                // Skip LLM entirely — go straight to verification.
                await MainActor.run {
                    isProcessing = false
                    showingVerification = true
                }
                return
            }
            if ocr.trimmingCharacters(in: .whitespacesAndNewlines).count < 30 {
                apiError = "OCR text is too short (\(ocr.count) chars). Try a clearer photo or a different file."
                showingErrorAlert = true
                isProcessing = false
                return
            }

            do {
                // Sprint 4.7ao-pdf-5d-tenth: if PDFKit native text
                // extraction gave us a date, USE IT. This bypasses
                // both the LLM (which often returns today) and the
                // OCR-text scan (which can't see the patient block
                // at Y=15.7%). The native text is REAL — not an
                // image — so the date is unambiguous.
                var dateFromExtraction = false
                if let pdfDate = pdfNativeDate, let parsed = Self.parseExtractionDate(pdfDate) {
                    date = parsed
                    dateFromExtraction = true
                    print("[SomaAI] document date set from PDF NATIVE text: \(parsed) (overriding OCR/LLM)")
                }
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
                // Sprint 4.7ao-pdf-5d-tenth: skip LLM date extraction
                // if PDF native text already gave us a reliable date.
                if !dateFromExtraction {
                    if let dateString = extraction.date, !dateString.isEmpty,
                       let parsed = Self.parseExtractionDate(dateString) {
                        // Reject "today" answers: if LLM's date is within 1 day of
                        // now, assume it was a guess and look in the OCR text.
                        let calendar = Calendar.current
                        let isToday = calendar.isDateInToday(parsed)
                        if !isToday {
                            date = parsed
                            dateFromExtraction = true
                            print("[SomaAI] document date set from extraction: \(parsed) (was \(date))")
                        } else {
                            print("[SomaAI] LLM returned today's date (\(parsed)) — treating as 'not found'")
                        }
                    }
                    if !dateFromExtraction {
                        // Fallback: scan the OCR text for any DD.MM.YYYY-style
                        // date. LocalExtractor.extractBestDate uses Russian
                        // month names + numeric formats.
                        if let found = LocalExtractor.extractBestDate(ocr),
                           let parsed = Self.parseExtractionDate(found) {
                            date = parsed
                            dateFromExtraction = true
                            print("[SomaAI] document date set from OCR-text scan: \(parsed) (found='\(found)')")
                        } else {
                            print("[SomaAI] document date left as today: \(date)")
                        }
                    }
                }
                // Sprint 4.7ao-pdf-5g: bubble the dateIsFromExtraction
                // flag up to the @State so the DatePicker can show a
                // small hint that the displayed date is the real one.
                dateIsFromExtraction = dateFromExtraction
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


// MARK: - Sprint 4.9b: date parsing from LLM extraction
extension AddLabTestView {
    /// Parses dates from various formats the LLM or LocalExtractor may return.
    /// Supports: ISO "YYYY-MM-DD", "DD.MM.YYYY", "DD/MM/YYYY", "DD-MM-YYYY",
    /// "YYYY/MM/DD". Returns nil if unparseable.
    static func parseExtractionDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let formatters: [(String, String)] = [
            ("yyyy-MM-dd", "ISO"),
            ("dd.MM.yyyy", "RU"),
            ("dd/MM/yyyy", "EU"),
            ("dd-MM-yyyy", "EU-dash"),
            ("yyyy/MM/dd", "ISO-slash"),
        ]

        for (fmt, _) in formatters {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            df.timeZone = TimeZone.current
            if let d = df.date(from: trimmed) {
                return d
            }
        }
        // Fallback: try "17.11.25" → assume 20YY
        let shortPattern = #"^(\d{1,2})[./-](\d{1,2})[./-](\d{2})$"#
        if let re = try? NSRegularExpression(pattern: shortPattern),
           let m = re.firstMatch(in: trimmed, range: NSRange(location: 0, length: (trimmed as NSString).length)) {
            let ns = trimmed as NSString
            let d = Int(ns.substring(with: m.range(at: 1))) ?? 0
            let mo = Int(ns.substring(with: m.range(at: 2))) ?? 0
            var y = Int(ns.substring(with: m.range(at: 3))) ?? 0
            y += 2000  // assume 21st century
            var comps = DateComponents()
            comps.year = y; comps.month = mo; comps.day = d
            if let date = Calendar.current.date(from: comps) { return date }
        }
        return nil
    }
}
