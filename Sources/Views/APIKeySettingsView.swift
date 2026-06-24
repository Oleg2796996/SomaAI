import SwiftUI

struct APIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (() -> Void)? = nil

    @State private var apiKey: String = ""
    @State private var baseURL: String = ""
    @State private var modelName: String = ""
    @State private var statusMessage: String = ""
    @State private var isSuccess: Bool = false
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Soma API Key")) {
                    SecureField("Enter API Key", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Base URL", text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Model Name", text: $modelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Your key is stored securely in the iOS Keychain. Base URL and model name are saved in UserDefaults. They are only used for API calls.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Save Key") {
                        do {
                            try KeychainHelper.shared.save(apiKey)
                            UserDefaults.standard.set(baseURL, forKey: "soma_api_base_url")
                            UserDefaults.standard.set(modelName, forKey: "soma_api_model_name")
                            statusMessage = "API settings saved successfully."
                            isSuccess = true
                            onSave?()
                        } catch {
                            statusMessage = "Failed to save: \(error.localizedDescription)"
                            isSuccess = false
                        }
                        showAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(apiKey.isEmpty)

                    Button("Delete Key") {
                        do {
                            try KeychainHelper.shared.delete()
                            apiKey = ""
                            baseURL = ""
                            modelName = ""
                            UserDefaults.standard.removeObject(forKey: "soma_api_base_url")
                            UserDefaults.standard.removeObject(forKey: "soma_api_model_name")
                            statusMessage = "API key deleted."
                            isSuccess = true
                        } catch {
                            statusMessage = "Failed to delete: \(error.localizedDescription)"
                            isSuccess = false
                        }
                        showAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.red)
                }

                if !statusMessage.isEmpty {
                    Section {
                        Text(statusMessage)
                            .foregroundColor(isSuccess ? .green : .red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("API Key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                do {
                    apiKey = try KeychainHelper.shared.read()
                } catch {
                    apiKey = ""
                }
                baseURL = UserDefaults.standard.string(forKey: "soma_api_base_url") ?? ""
                modelName = UserDefaults.standard.string(forKey: "soma_api_model_name") ?? ""
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text(isSuccess ? "Success" : "Error"),
                      message: Text(statusMessage),
                      dismissButton: .default(Text("OK")))
            }
        }
    }
}
