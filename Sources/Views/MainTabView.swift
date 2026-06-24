import SwiftUI
import SwiftData
import PhotosUI
import Vision
import PDFKit

// MARK: - API Models
struct SomaBrainResponse: Codable {
    let markers: [SomaMarker]
}

struct SomaMarker: Codable, Identifiable {
    var id: String { name + (unit ?? "") }
    var name: String
    var value: String
    var unit: String?
    var referenceRange: String?
    var flag: String? // High, Low, Normal
}

class SomaAPIClient {
    static let shared = SomaAPIClient()
    private let defaultBaseURL = "https://ai.wormsoft.ru/api/gpt"
    private let defaultModelName = "wormsoft/code/medium"

    private var apiKey: String {
        do {
            return try KeychainHelper.shared.read()
        } catch {
            return ""
        }
    }

    private var baseURL: String {
        let saved = UserDefaults.standard.string(forKey: "soma_api_base_url")
        return (saved?.isEmpty == false) ? saved! : defaultBaseURL
    }

    private var modelName: String {
        let saved = UserDefaults.standard.string(forKey: "soma_api_model_name")
        return (saved?.isEmpty == false) ? saved! : defaultModelName
    }

    private var chatEndpoint: String {
        var url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while url.hasSuffix("/") { url.removeLast() }
        if url.hasSuffix("/v1") || url.hasSuffix("/v1/chat") {
            return url + "/chat/completions"
        } else if url.contains("wormsoft") || url.contains("/api/gpt") {
            return url + "/v1/chat/completions"
        } else {
            return url + "/v1/chat/completions"
        }
    }

    func structureText(_ text: String) async throws -> [SomaMarker] {
        guard !apiKey.isEmpty else {
            throw NSError(domain: "SomaAPI", code: -2, userInfo: [NSLocalizedDescriptionKey: "API key not configured. Go to Settings → API Key."])
        }

        guard let url = URL(string: chatEndpoint) else {
            throw NSError(domain: "SomaAPI", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid API endpoint: \(chatEndpoint)"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let messages: [[String: String]] = [
            ["role": "system", "content": "You extract medical lab markers from raw OCR text and return ONLY a JSON object with a 'markers' array. Each marker has: name, value, unit (optional), referenceRange (optional), flag (optional: High/Low/Normal). No markdown, no explanations."],
            ["role": "user", "content": text]
        ]
        let body: [String: Any] = [
            "model": modelName,
            "messages": messages,
            "temperature": 0.1
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "SomaAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard httpResponse.statusCode == 200 else {
            throw NSError(domain: "SomaAPI", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server returned \(httpResponse.statusCode)"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8) else {
            throw NSError(domain: "SomaAPI", code: 0, userInfo: [NSLocalizedDescriptionKey: "Could not parse API response"])
        }

        let decoded = try JSONDecoder().decode(SomaBrainResponse.self, from: contentData)
        return decoded.markers
    }
}

// MARK: - Camera Integration
struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let uiImage = info[.originalImage] as? UIImage {
                parent.image = uiImage
            }
            parent.dismiss()
        }
    }
}

struct MainTabView: View {
    @State private var currentLanguage: String = "English"
    
    var body: some View {
        TabView {
            ProfileView(language: $currentLanguage)
                .tabItem {
                    Label(Localization.somaTranslate("tab_profile", language: currentLanguage), systemImage: "person.fill")
                }

            LabVaultView(language: currentLanguage)
                .tabItem {
                    Label(Localization.somaTranslate("tab_vault", language: currentLanguage), systemImage: "folder.fill")
                }

            BrainView()
                .tabItem {
                    Label(Localization.somaTranslate("tab_brain", language: currentLanguage), systemImage: "brain.head.profile")
                }
        }
        .environment(\.locale, .init(identifier: currentLanguage == "Русский" ? "ru" : "en"))
    }
}

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    
    @Binding var language: String
    
    @State private var fullName: String = ""
    @State private var birthDate: Date = Date()
    @State private var gender: String = "Male"
    @State private var bloodType: String = ""
    @State private var height: String = ""
    @State private var weight: String = ""
    
    @FocusState private var focusedField: Bool
    
    let genders = ["Male", "Female", "Other"]
    let languages = ["English", "Русский"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section(Localization.somaTranslate("section_personal", language: language)) {
                    TextField(Localization.somaTranslate("field_name", language: language), text: $fullName)
                        .focused($focusedField)
                    DatePicker(Localization.somaTranslate("field_birthdate", language: language), selection: $birthDate, displayedComponents: .date)
                    Picker(Localization.somaTranslate("field_gender", language: language), selection: $gender) {
                        ForEach(genders, id: \.self) { g in
                            Text(Localization.somaTranslate("gender_\(g.lowercased())", language: language))
                        }
                    }
                }
                
                Section(Localization.somaTranslate("section_health", language: language)) {
                    HStack {
                        Text(Localization.somaTranslate("field_blood", language: language))
                        Spacer()
                        TextField("", text: $bloodType)
                            .focused($focusedField)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text(Localization.somaTranslate("field_height", language: language))
                        Spacer()
                        TextField("", text: $height)
                            .focused($focusedField)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                    HStack {
                        Text(Localization.somaTranslate("field_weight", language: language))
                        Spacer()
                        TextField("", text: $weight)
                            .focused($focusedField)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.decimalPad)
                    }
                }
                
                Section(Localization.somaTranslate("section_settings", language: language)) {
                    Picker(Localization.somaTranslate("field_language", language: language), selection: $language) {
                        ForEach(languages, id: \.self) { Text($0) }
                    }

                    NavigationLink(destination: APIKeySettingsView(onSave: { settingsRefresh = UUID() })) {
                        HStack {
                            Text("Soma API Key")
                            Spacer()
                            if (try? KeychainHelper.shared.read()) != nil {
                                Image(systemName: "checkmark.seal.fill")
                                    .foregroundColor(.green)
                            } else {
                                Text("Not set")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                
                Section {
                    Button(action: saveProfile) {
                        Text(Localization.somaTranslate("button_save", language: language))
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.spring(), value: isPressed)
                }
            }
            .navigationTitle(Localization.somaTranslate("profile_title", language: language))
            .id(settingsRefresh)
            .onAppear(perform: loadProfile)
        }
    }
    
    @State private var isPressed = false
    @State private var settingsRefresh = UUID()
    
    private func loadProfile() {
        if let profile = profiles.first {
            fullName = profile.fullName
            birthDate = profile.birthDate
            gender = profile.gender
            bloodType = profile.bloodType ?? ""
            height = profile.height != nil ? String(profile.height!) : ""
            weight = profile.weight != nil ? String(profile.weight!) : ""
            language = profile.preferredLanguage
        }
    }
    
    private func saveProfile() {
        focusedField = false
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isPressed = false
        }
        
        if let profile = profiles.first {
            profile.fullName = fullName
            profile.birthDate = birthDate
            profile.gender = gender
            profile.bloodType = bloodType
            profile.height = Double(height)
            profile.weight = Double(weight)
            profile.preferredLanguage = language
        } else {
            let newProfile = UserProfile(fullName: fullName, birthDate: birthDate, gender: gender, preferredLanguage: language)
            newProfile.bloodType = bloodType
            newProfile.height = Double(height)
            newProfile.weight = Double(weight)
            modelContext.insert(newProfile)
        }
    }
}

struct LabVaultView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LabTest.date, order: .reverse) private var tests: [LabTest]
    let language: String
    
    @State private var showingAddSheet = false
    
    var body: some View {
        NavigationStack {
            List {
                if tests.isEmpty {
                    ContentUnavailableView(
                        Localization.somaTranslate("vault_empty_title", language: language),
                        systemImage: "folder.badge.plus",
                        description: Text(Localization.somaTranslate("vault_empty_desc", language: language))
                    )
                } else {
                    ForEach(tests) { test in
                        NavigationLink(destination: LabTestDetailView(test: test, language: language)) {
                            VStack(alignment: .leading) {
                                Text(test.testName)
                                    .font(.headline)
                                Text(test.date, style: .date)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete(perform: deleteTests)
                }
            }
            .navigationTitle(Localization.somaTranslate("tab_vault", language: language))
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingAddSheet = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddSheet) {
                AddLabTestView(language: language)
            }
        }
    }
    
    private func deleteTests(offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(tests[index])
        }
    }
}

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
                            Label("Take Photo", systemImage: "camera.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                        
                        PhotosPicker(selection: $selectedItems, matching: .images) {
                            Label("Scan Photos (Multi)", systemImage: "photo.on.rectangle.angled")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                        
                        Button(action: { isImportingPDF = true }) {
                            Label("Import PDF", systemImage: "doc.text.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(isProcessing)
                    }
                }
                
                if !recognizedText.isEmpty {
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
                    .disabled(isProcessing)
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.spring(), value: isPressed)
                }
            }
            .navigationTitle(Localization.somaTranslate("add_test_title", language: language))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedItems) { oldValue, newValue in
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
        do {
            let text = try await performOCR(on: image)
            recognizedText = text
        } catch {
            print("OCR Error: \(error)")
        }
        isProcessing = false
    }
    
    private func handleImageSelection() async {
        guard !selectedItems.isEmpty else { return }
        isProcessing = true
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
        isProcessing = false
    }
    
    private func handlePDFSelection(url: URL) async {
        isProcessing = true
        var allText = ""
        
        do {
            if let pdf = PDFDocument(url: url) {
                let pageCount = pdf.pageCount
                var images = [UIImage]()
                
                for i in 0..<pageCount {
                    if let page = pdf.page(at: i) {
                        // Use built-in PDFPage thumbnail renderer for maximum compatibility
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
            print("PDF Processing Error: \(error)")
        }
        
        recognizedText = allText
        isProcessing = false
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
                let errorMessage = error.localizedDescription
                apiError = errorMessage
                showingErrorAlert = true
                print("API Error: \(errorMessage)")
            }
            isProcessing = false
        }
    }
    
    private func saveFinalTest(with markers: [SomaMarker]) {
        let newTest = LabTest(date: date, provider: provider, testName: testName)
        
        for m in markers {
            let marker = LabMarker(name: m.name, value: m.value, unit: m.unit)
            newTest.markers.append(marker)
        }
        
        modelContext.insert(newTest)
        dismiss()
    }
}

struct VerificationView: View {
    @Binding var markers: [SomaMarker]
    let language: String
    var onConfirm: ([SomaMarker]) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Verify Recognized Markers")) {
                    ForEach($markers) { $marker in
                        HStack {
                            TextField("Name", text: $marker.name)
                            TextField("Value", text: $marker.value)
                            TextField("Unit", text: Binding(
                                get: { marker.unit ?? "" },
                                set: { marker.unit = $0 }
                            ))
                            .frame(width: 60)
                        }
                    }
                    .onDelete { indexSet in
                        markers.remove(atOffsets: indexSet)
                    }
                }
            }
            .navigationTitle("Verify Data")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Confirm") {
                        onConfirm(markers)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}

struct LabTestDetailView: View {
    let test: LabTest
    let language: String
    
    var body: some View {
        VStack {
            Text(test.testName)
                .font(.title)
                .fontWeight(.bold)
            Text(test.provider)
                .foregroundColor(.secondary)
            
            Divider().padding()
            
            if test.markers.isEmpty {
                Text("Markers will appear here")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                List(test.markers) { marker in
                    HStack {
                        Text(marker.name)
                        Spacer()
                        Text(marker.value)
                            .fontWeight(.bold)
                        Text(marker.unit ?? "")
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle(Localization.somaTranslate("test_detail_title", language: language))
    }
}

struct BrainView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                Text("AI Consultant Interface")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Soma Brain")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
