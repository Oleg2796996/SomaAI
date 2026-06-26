import SwiftUI
import SwiftData
import UIKit

struct BrainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \LabTest.date, order: .reverse) private var persistedTests: [LabTest]
    let passedInTests: [LabTest]

    private var tests: [LabTest] { persistedTests.isEmpty ? passedInTests : persistedTests }

    /// Use the view's own language, falling back to Localization default.
    private var effectiveLanguage: String {
        // The view is given a language by MainTabView; just use it.
        return language
    }

    let language: String

    @State private var messages: [ChatMessage] = [
        ChatMessage(role: .assistant, text: Localization.somaTranslate("brain_welcome_message", language: language))
    ]
    @State private var inputText: String = ""
    @State private var isLoading = false
    @State private var scrollTarget: UUID?
    @State private var errorMessage: String? = nil
    @State private var showingError = false
    @FocusState private var inputFocused: Bool

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

                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        TextField(Localization.somaTranslate("brain_input_placeholder", language: language), text: $inputText)
                            .textFieldStyle(.roundedBorder)
                            .submitLabel(.send)
                            .focused($inputFocused)
                            .onSubmit { sendMessage() }
                            .disabled(isLoading)

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

                    Text(Localization.somaTranslate("brain_disclaimer_footer", language: language))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(.ultraThinMaterial)
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { inputFocused = false }
                    }
                }
            }
            .navigationTitle("Soma Brain")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.immediately)
            .alert("Brain Error", isPresented: $showingError, presenting: errorMessage) { _ in
                Button("OK") {}
            } message: { error in
                Text(error)
            }
        }
    }

    /// Hard-resign first responder from any active text field.
    /// Needed because @FocusState dismissal can race with the async Task.
    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func sendMessage() {
        let question = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        // Dismiss keyboard on the main thread BEFORE the async work,
        // otherwise the new bubble lands under the keyboard.
        inputFocused = false
        dismissKeyboard()

        let userMessage = ChatMessage(role: .user, text: question)
        messages.append(userMessage)
        scrollTarget = userMessage.id
        inputText = ""
        isLoading = true

        Task {
            do {
                let context = buildContextFragments(for: question)
                let reply = try await SomaAPIClient.shared.askConsultant(question, context: context, language: language)
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

    /// Build context for the LLM consultant.
    /// Strategy:
    ///  1. Try keyword match (RU + EN) on marker name.
    ///  2. If nothing matched, send ALL tests (general questions like "что у меня").
    ///  3. If there are no tests at all, return empty so the model can answer honestly.
    private func buildContextFragments(for question: String) -> [String: String] {
        let lowercased = question.lowercased()
        var fragments: [String: String] = [:]
        var anyMatch = false

        for test in tests {
            // --- Lab markers (existing) ---
            for marker in test.markers {
                let nameLower = marker.name.lowercased()
                let nameWords = nameLower.split(separator: " ")
                let synonyms = markerSynonyms(for: nameLower)

                let hit = lowercased.contains(nameLower)
                    || nameWords.contains(where: { lowercased.contains(String($0)) })
                    || synonyms.contains(where: { lowercased.contains($0) })

                if hit {
                    anyMatch = true
                    let key = "\(test.testName) — \(marker.name)"
                    var line = "Value: \(marker.value) \(marker.unit ?? "")"
                    if let range = marker.referenceRange, !range.isEmpty { line += " | Ref: \(range)" }
                    if let flag = marker.flag, !flag.isEmpty { line += " | Flag: \(flag)" }
                    fragments[key] = line
                }
            }
            // --- Prescriptions (new) ---
            for med in test.prescriptions {
                let nameLower = med.name.lowercased()
                if nameLower.isEmpty { continue }
                let hit = lowercased.contains(nameLower)
                    || nameLower.split(separator: " ").contains(where: { lowercased.contains(String($0)) })
                if hit {
                    anyMatch = true
                    let key = "\(test.testName) — \(med.name)"
                    var line = "Medication"
                    if let d = med.dose, !d.isEmpty { line += " \(d)" }
                    if let f = med.frequency, !f.isEmpty { line += ", \(f)" }
                    if let du = med.duration, !du.isEmpty { line += ", \(du)" }
                    fragments[key] = line
                }
            }
            // --- Structured fields (epicrisis / consultation / unknown) ---
            for field in test.structuredFields {
                let keyLower = field.key.lowercased()
                let valueLower = field.value.lowercased()
                let hit = lowercased.contains(keyLower)
                    || lowercased.contains(valueLower)
                    || keyLower.split(separator: " ").contains(where: { lowercased.contains(String($0)) })
                if hit {
                    anyMatch = true
                    let key = "\(test.testName) — \(field.key)"
                    fragments[key] = field.value
                }
            }
        }

        // Fallback: if user asks a general question (no specific keyword),
        // ship the full Health Passport so the consultant has data to work with.
        if !anyMatch && !tests.isEmpty {
            for test in tests {
                for marker in test.markers {
                    let key = "\(test.testName) — \(marker.name)"
                    var line = "Value: \(marker.value) \(marker.unit ?? "")"
                    if let range = marker.referenceRange, !range.isEmpty { line += " | Ref: \(range)" }
                    if let flag = marker.flag, !flag.isEmpty { line += " | Flag: \(flag)" }
                    fragments[key] = line
                }
                for med in test.prescriptions {
                    if med.name.isEmpty { continue }
                    let key = "\(test.testName) — \(med.name)"
                    var line = "Medication"
                    if let d = med.dose, !d.isEmpty { line += " \(d)" }
                    if let f = med.frequency, !f.isEmpty { line += ", \(f)" }
                    if let du = med.duration, !du.isEmpty { line += ", \(du)" }
                    fragments[key] = line
                }
                for field in test.structuredFields {
                    fragments["\(test.testName) — \(field.key)"] = field.value
                }
            }
        }

        return fragments
    }

    /// Russian ↔ English synonyms for common lab markers. Extend as needed.
    private func markerSynonyms(for markerName: String) -> [String] {
        let dict: [String: [String]] = [
            "лейкоциты": ["wbc", "white blood", "white blood cells", "leukocytes", "leukocyte"],
            "эритроциты": ["rbc", "red blood", "red blood cells", "erythrocytes", "erythrocyte"],
            "гемоглобин": ["hgb", "hb", "hemoglobin", "haemoglobin"],
            "гематокрит": ["hct", "hematocrit", "haematocrit"],
            "тромбоциты": ["plt", "platelets", "thrombocytes", "thrombocyte"],
            "кетоны": ["ketones", "ketone", "кетоновые тела"],
            "глюкоза": ["glucose", "сахар", "sugar"],
            "белок": ["protein", "общий белок", "total protein"],
            "билирубин": ["bilirubin"],
            "креатинин": ["creatinine", "crea"],
            "мочевина": ["urea", "urea nitrogen", "bun"],
            "аld": [],
            "аст": ["ast", "aspartate"],
            "алт": ["alt", "alanine"],
            "ph": ["кислотность", "acidity"]
        ]
        for (key, values) in dict {
            if markerName.contains(key) || key.contains(markerName) {
                return values
            }
        }
        return []
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
