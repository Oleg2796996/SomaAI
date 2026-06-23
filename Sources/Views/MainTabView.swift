import SwiftUI
import SwiftData
import PhotosUI
import Vision

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
            .onAppear(perform: loadProfile)
        }
    }
    
    @State private var isPressed = false
    
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
    
    @State private var selectedItem: PhotosPickerItem? = nil
    @State private var recognizedText: String = ""
    @State private var isProcessing = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text(Localization.somaTranslate("add_test_section", language: language))) {
                    TextField(Localization.somaTranslate("field_test_name", language: language), text: $testName)
                    TextField(Localization.somaTranslate("field_provider", language: language), text: $provider)
                    DatePicker(Localization.somaTranslate("field_date", language: language), selection: $date, displayedComponents: .date)
                }
                
                Section {
                    PhotosPicker(selection: $selectedItem, matching: .images) {
                        Label(Localization.somaTranslate("button_scan", language: language), systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isProcessing)
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
                    Button(action: saveTest) {
                        Text(Localization.somaTranslate("button_save", language: language))
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
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
            .onChange(of: selectedItem) { oldValue, newValue in
                Task {
                    await handleImageSelection()
                }
            }
        }
    }
    
    private func handleImageSelection() async {
        guard let item = selectedItem else { return }
        isProcessing = true
        
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                recognizedText = try await performOCR(on: image)
            }
        } catch {
            print("OCR Error: \(error)")
            recognizedText = "Error processing image."
        }
        
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
    
    private func saveTest() {
        isPressed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isPressed = false
        }
        
        // В полноценном Soma Brain здесь будет await API.structure(recognizedText)
        // Для текущего этапа сохраняем базовые данные, чтобы проверить цепочку.
        let newTest = LabTest(date: date, provider: provider, testName: testName)
        modelContext.insert(newTest)
        dismiss()
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
