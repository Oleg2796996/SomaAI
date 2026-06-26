import SwiftUI
import SwiftData

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
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: test.documentType.iconName)
                                    .font(.title3)
                                    .foregroundColor(.accentColor)
                                    .frame(width: 28, height: 28)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(test.testName)
                                        .font(.headline)
                                    HStack(spacing: 6) {
                                        Text(test.date, style: .date)
                                            .font(.subheadline)
                                            .foregroundColor(.secondary)
                                        Text("·").foregroundColor(.secondary)
                                        Text(test.documentType.displayNameRU)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text(subtitle(for: test))
                                        .font(.caption)
                                        .foregroundColor(subtitleColor(for: test))
                                }
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

    /// Subtitle shown under the document name. Adapted to documentType.
    private func subtitle(for test: LabTest) -> String {
        let isRU = (language == "Русский" || language == "Russian")
        switch test.documentType {
        case .labResult:
            let n = test.markers.count
            return isRU
                ? "\(n) показател\(n == 1 ? "ь" : (n >= 2 && n <= 4 ? "я" : "ей"))"
                : "\(n) marker\(n == 1 ? "" : "s")"
        case .prescription:
            let n = test.prescriptions.count
            return isRU
                ? "\(n) препарат\(n == 1 ? "" : (n >= 2 && n <= 4 ? "а" : "ов"))"
                : "\(n) medication\(n == 1 ? "" : "s")"
        case .epicrisis, .dischargeSummary, .consultation, .referral, .imagingReport, .vaccination, .unknown:
            let n = test.structuredFields.count
            if n == 0 { return isRU ? "Нет разделов" : "No sections" }
            return isRU ? "\(n) раздел\(n == 1 ? "" : (n >= 2 && n <= 4 ? "а" : "ов"))" : "\(n) section\(n == 1 ? "" : "s")"
        }
    }

    private func subtitleColor(for test: LabTest) -> Color {
        switch test.documentType {
        case .labResult: return test.markers.isEmpty ? .red : .secondary
        case .prescription: return test.prescriptions.isEmpty ? .red : .secondary
        default: return test.structuredFields.isEmpty ? .red : .secondary
        }
    }
}
