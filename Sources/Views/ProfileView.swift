import SwiftUI
import SwiftData

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
