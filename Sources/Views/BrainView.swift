import SwiftUI
import SwiftData

struct BrainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LabTest.date, order: .reverse) private var tests: [LabTest]
    @Query private var userProfiles: [UserProfile]

    @State private var messages: [ChatMessage] = []
    @State private var inputText: String = ""
    @State private var isLoading = false
    @State private var scrollTarget: UUID?
    @State private var errorMessage: String? = nil
    @State private var showingError = false
    @FocusState private var isFocused: Bool

    private var currentLanguage: String {
        userProfiles.first?.preferredLanguage ?? "English"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List(messages) { message in
                    HStack {
                        if message.role == .user { Spacer(minLength: 20) }
                        VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                            Text(message.text)
                                .padding(12)
                                .background(message.role == .user ? Color.blue.opacity(0.2) : Color.gray.opacity(0.15))
                                .foregroundColor(.primary)
                                .cornerRadius(16)
                            Text(message.sourceLabel)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if message.role == .assistant { Spacer(minLength: 20) }
                    }
                    .listRowSeparator(.hidden)
                    .id(message.id)
                }
                .listStyle(.plain)
                .scrollPosition(id: $scrollTarget, anchor: .bottom)
                .onTapGesture {
                    isFocused = false
                }

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        TextField(Localization.somaTranslate("brain_input_placeholder", language: currentLanguage), text: $inputText, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .disabled(isLoading)
                            .focused($isFocused)

                        Button(action: sendMessage) {
                            if isLoading {
                                ProgressView()
                                    .progressViewStyle(.circular)
                            } else {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.title2)
                            }
                        }
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
                    }

                    Text(Localization.somaTranslate("brain_disclaimer_footer", language: currentLanguage))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
            .navigationTitle("Soma Brain")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Brain Error", isPresented: $showingError, presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { error in
                Text(error)
            }
            .onAppear {
                if messages.isEmpty {
                    messages.append(ChatMessage(role: .assistant, text: Localization.somaTranslate("brain_welcome_message", language: currentLanguage)))
                }
            }
        }
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        let userMessage = ChatMessage(role: .user, text: question)
        messages.append(userMessage)
        scrollTarget = userMessage.id
        inputText = ""
        isFocused = false
        isLoading = true

        Task {
            do {
                let context = buildContextFragments(for: question)
                let reply = try await SomaAPIClient.shared.askConsultant(question, context: context)
                await MainActor.run {
                    let assistantMessage = ChatMessage(role: .assistant, text: reply, source: .cloud)
                    messages.append(assistantMessage)
                    scrollTarget = assistantMessage.id
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    showingError = true
                    isLoading = false
                }
            }
        }
    }

    private func buildContextFragments(for question: String) -> [String: String] {
        var fragments: [String: String] = [:]
        let lowercased = question.lowercased()

        for test in tests {
            for marker in test.markers {
                let markerKey = marker.name.lowercased()
                if lowercased.contains(markerKey) || markerKey.split(separator: " ").contains(where: { lowercased.contains(String($0)) }) {
                    let key = "\(test.testName) — \(marker.name)"
                    fragments[key] = "\(marker.value) \(marker.unit ?? "") (ref: \(marker.referenceRange ?? "n/a"))"
                }
            }
        }

        return fragments
    }
}

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: MessageRole
    let text: String
    var source: MessageSource = .local

    var sourceLabel: String {
        switch role {
        case .user: return "You"
        case .assistant: return source == .cloud ? "Soma Brain ☁️" : "Soma Brain 📱"
        }
    }
}

enum MessageRole {
    case user
    case assistant
}

enum MessageSource {
    case local
    case cloud
}
