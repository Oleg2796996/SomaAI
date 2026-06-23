import SwiftUI
import SwiftData

struct MainTabView: View {
    var body: some View {
        TabView {
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }

            LabVaultView()
                .tabItem {
                    Label("Vault", systemImage: "folder.fill")
                }

            BrainView()
                .tabItem {
                    Label("Brain", systemImage: "brain.head.profile")
                }
        }
    }
}

struct ProfileView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var profiles: [UserProfile]
    
    @State private var fullName: String = ""
    @State private var birthDate: Date = Date()
    @State private var gender: String = "Male"
    @State private var bloodType: String = ""
    @State private var height: String = ""
    @State private var weight: String = ""
    @State private var language: String = "English"
    
    let genders = ["Male", "Female", "Other"]
    let languages = ["English", "Русский"]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Personal Information") {
                    TextField("Full Name", text: $fullName)
                    DatePicker("Birth Date", selection: $birthDate, displayedComponents: .date)
                    Picker("Gender", selection: $gender) {
                        ForEach(genders, id: \.self) { Text($0) }
                    }
                }
                
                Section("Health Data") {
                    TextField("Blood Type", text: $bloodType)
                    HStack {
                        TextField("Height (cm)", text: $height)
                        TextField("Weight (kg)", text: $weight)
                    }
                }
                
                Section("App Settings") {
                    Picker("UI Language", selection: $language) {
                        ForEach(languages, id: \.self) { Text($0) }
                    }
                }
                
                Section {
                    Button(action: saveProfile) {
                        Text("Save Profile")
                            .frame(maxWidth: .infinity)
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .navigationTitle("Soma Profile")
            .onAppear(perform: loadProfile)
        }
    }
    
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
