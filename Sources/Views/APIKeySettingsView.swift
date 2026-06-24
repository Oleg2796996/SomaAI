import SwiftUI

struct APIKeySettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var apiKey: String = ""
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
                    Text("Your key is stored securely in the iOS Keychain and never leaves this device except in API calls to Wormsoft.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button("Save Key") {
                        do {
                            try KeychainHelper.shared.save(apiKey)
                            statusMessage = "API key saved successfully."
                            isSuccess = true
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
            }
            .alert(isPresented: $showAlert) {
                Alert(title: Text(isSuccess ? "Success" : "Error"),
                      message: Text(statusMessage),
                      dismissButton: .default(Text("OK")))
            }
        }
    }
}
