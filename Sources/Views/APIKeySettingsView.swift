import SwiftUI

/// Sprint 4.7f: multi-provider API key UI.
/// Two sections: Wormsoft (legacy single-key flow + base URL + model name)
/// and OpenAI (Sprint 4.7e — just the key, endpoint + model hardcoded).
struct APIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: (() -> Void)? = nil

    // Wormsoft (backward-compat, uses pre-4.7e single-key flow)
    @State private var wormsoftKey: String = ""
    @State private var wormsoftBaseURL: String = ""
    @State private var wormsoftModelName: String = ""

    // OpenAI (Sprint 4.7e)
    @State private var openaiKey: String = ""

    @State private var statusMessage: String = ""
    @State private var isSuccess: Bool = false
    @State private var showAlert = false

    var body: some View {
        NavigationStack {
            Form {
                // ═════════ Wormsoft Section ═════════
                Section(header: Text("Soma API Key (Wormsoft)")) {
                    SecureField("Enter Wormsoft API Key", text: $wormsoftKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("Base URL", text: $wormsoftBaseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextField("Model Name", text: $wormsoftModelName)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("Wormsoft key stored in iOS Keychain (account: soma_api_key_wormsoft). Base URL and model name saved in UserDefaults.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Current: \(KeychainHelper.shared.masked(accountName: APIProvider.wormsoft.keychainAccount))")
                        .font(.caption2)
                        .foregroundColor(.tertiary)
                }

                Section {
                    Button("Save Wormsoft") {
                        do {
                            try KeychainHelper.shared.save(
                                wormsoftKey,
                                accountName: APIProvider.wormsoft.keychainAccount
                            )
                            UserDefaults.standard.set(wormsoftBaseURL, forKey: "soma_api_base_url")
                            UserDefaults.standard.set(wormsoftModelName, forKey: "soma_api_model_name")
                            statusMessage = "Wormsoft API settings saved."
                            isSuccess = true
                            onSave?()
                        } catch {
                            statusMessage = "Failed to save Wormsoft: \(error.localizedDescription)"
                            isSuccess = false
                        }
                        showAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(wormsoftKey.isEmpty)

                    Button("Delete Wormsoft Key") {
                        do {
                            try KeychainHelper.shared.delete(
                                accountName: APIProvider.wormsoft.keychainAccount
                            )
                            wormsoftKey = ""
                            UserDefaults.standard.removeObject(forKey: "soma_api_base_url")
                            UserDefaults.standard.removeObject(forKey: "soma_api_model_name")
                            wormsoftBaseURL = ""
                            wormsoftModelName = ""
                            statusMessage = "Wormsoft API key deleted."
                            isSuccess = true
                        } catch {
                            statusMessage = "Failed to delete Wormsoft: \(error.localizedDescription)"
                            isSuccess = false
                        }
                        showAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundColor(.red)
                }

                // ═════════ OpenAI Section ═════════
                Section(header: Text("OpenAI (fallback provider)")) {
                    SecureField("Enter OpenAI API Key", text: $openaiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("OpenAI key stored in iOS Keychain (account: soma_api_key_openai). Endpoint \(APIProvider.openai.baseURL) and default model \(APIProvider.openai.defaultModel) are hardcoded in APIProvider enum.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Current: \(KeychainHelper.shared.masked(accountName: APIProvider.openai.keychainAccount))")
                        .font(.caption2)
                        .foregroundColor(.tertiary)
                }

                Section {
                    Button("Save OpenAI Key") {
                        do {
                            try KeychainHelper.shared.save(
                                openaiKey,
                                accountName: APIProvider.openai.keychainAccount
                            )
                            statusMessage = "OpenAI key saved. Will be used as fallback if Wormsoft times out."
                            isSuccess = true
                            onSave?()
                        } catch {
                            statusMessage = "Failed to save OpenAI: \(error.localizedDescription)"
                            isSuccess = false
                        }
                        showAlert = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(openaiKey.isEmpty)

                    Button("Delete OpenAI Key") {
                        do {
                            try KeychainHelper.shared.delete(
                                accountName: APIProvider.openai.keychainAccount
                            )
                            openaiKey = ""
                            statusMessage = "OpenAI key deleted."
                            isSuccess = true
                        } catch {
                            statusMessage = "Failed to delete OpenAI: \(error.localizedDescription)"
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
            .navigationTitle("API Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Sprint 4.7g: auto-migrate legacy 'default' key into 'soma_api_key_wormsoft'.
                _ = KeychainHelper.shared.migrateLegacyDefaultAccount()

                // Log current state so we can see in console whether keys are present.
                print("[SomaAI] APIKeySettingsView.onAppear: wormsoft=\(KeychainHelper.shared.masked(accountName: APIProvider.wormsoft.keychainAccount)), openai=\(KeychainHelper.shared.masked(accountName: APIProvider.openai.keychainAccount))")

                // Load Wormsoft
                do {
                    wormsoftKey = try KeychainHelper.shared.read(accountName: APIProvider.wormsoft.keychainAccount)
                } catch {
                    wormsoftKey = ""
                }
                wormsoftBaseURL = UserDefaults.standard.string(forKey: "soma_api_base_url") ?? ""
                wormsoftModelName = UserDefaults.standard.string(forKey: "soma_api_model_name") ?? ""

                // Load OpenAI key (don't write into form unless user opens field)
                // Just show via masked() above. Form field starts empty for security.
                openaiKey = ""
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text(isSuccess ? "Success" : "Error"),
                      message: Text(statusMessage),
                      dismissButton: .default(Text("OK")))
            }
        }
    }
}