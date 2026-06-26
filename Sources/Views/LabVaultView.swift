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
                            VStack(alignment: .leading, spacing: 2) {
                                Text(test.testName)
                                    .font(.headline)
                                Text(test.date, style: .date)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                Text("\(test.markers.count) marker\(test.markers.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundColor(test.markers.isEmpty ? .red : .secondary)
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
