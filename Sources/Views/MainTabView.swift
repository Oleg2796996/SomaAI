import SwiftUI
import SwiftData

struct MainTabView: View {
    @State private var currentLanguage: String = "English"
    
    var body: some View {
        TabView {
            ProfileView(language: $currentLanguage)
                .tabItem {
                    Label(Localization.translate("tab_profile", language: currentLanguage), systemImage: "person.fill")
                }

            LabVaultView()
                .tabItem {
                    Label(Localization.translate("tab_vault", language: currentLanguage), systemImage: "folder.fill")
                }

            BrainView()
                .tabItem {
                    Label(Localization.translate("tab_brain", language: currentLanguage), systemImage: "brain.head.profile")
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
    
    let genders = ["Male", "Female", "Other"]
    let languages = ["English", "Русский"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section(Localization.translate("section_personal", language: language)) {
                    TextField(Localization.translate("field_name", language: language), text: $fullName)
                    DatePicker(Localization.translate("field_birthdate", language: language), selection: $birthDate, displayedComponents: .date)
                    Picker(Localization.translate("field_gender", language: language), selection: $gender) {
                        ForEach(genders, id: \.self) { g in
                            Text(Localization.translate("gender_\(g.lowercased())", language: language))
                        }
                    }
                }
                
                Section(Localization.translate("section_health", language: language)) {
                    TextField(Localization.translate("field_blood", language: language), text: $bloodType)
                    HStack {
                        TextField(Localization.translate("field_height", language: language), text: $height)
                        TextField(Localization.translate("field_weight", language: language), text: $weight)
                    }
                }
                
                Section(Localization.translate("section_settings", language: language)) {
                    Picker(Localization.translate("field_language", language: language), selection: $language) {
                        ForEach(languages, id: \.self) { Text($0) }
                    }
                }
                
                Section {
                    Button(action: saveProfile) {
                        Text(Localization.translate("button_save", language: language))
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .scaleEffect(isPressed ? 0.95 : 1.0)
                    .animation(.spring(), value: isPressed)
                }
            }
            .navigationTitle(Localization.translate("profile_title", language: language))
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
        // Visual feedback simulation
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
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                Text("Medical Records Archive")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Lab Vault")
            .navigationBarTitleDisplayMode(.inline)
        }
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
