import SwiftUI

/// Polymorphic detail view. Uses the same `switch documentType`
/// pattern as `VerificationView` so the detail screen matches the
/// structure the user verified in the sheet.
struct LabTestDetailView: View {
    let test: LabTest
    let language: String

    private var isRU: Bool { language == "Русский" || language == "Russian" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                Divider()
                bodySection
                // Sprint 4.7aa-debug: log marker flags once when detail view appears
                Color.clear.frame(height: 0)
                    .onAppear {
                        for (i, m) in test.markers.enumerated() {
                            print("[SomaAI-detail] marker[\(i)] name=\(m.name) value=\(m.value) flag=\(m.flag ?? \"NIL\")")
                        }
                    }
                Spacer(minLength: 40)
                Text(Localization.somaTranslate("disclaimer_data_only", language: language))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
        .navigationTitle(Localization.somaTranslate("test_detail_title", language: language))
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: test.documentType.iconName)
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text(test.testName)
                    .font(.title)
                    .fontWeight(.bold)
            }
            Text(test.documentType.displayNameRU)
                .font(.subheadline)
                .foregroundColor(.accentColor)
            if !test.provider.isEmpty {
                Text(test.provider)
                    .foregroundColor(.secondary)
            }
            Text(test.date, style: .date)
                .font(.subheadline)
                .foregroundColor(.secondary)
            if test.extractionConfidence < 1.0 {
                Text(isRU
                     ? "Уверенность распознавания: \(Int(test.extractionConfidence * 100))%"
                     : "Extraction confidence: \(Int(test.extractionConfidence * 100))%")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        switch test.documentType {
        case .labResult:
            markersBody
        case .prescription:
            prescriptionsBody
        case .epicrisis, .dischargeSummary, .consultation, .referral, .imagingReport, .vaccination, .unknown:
            structuredBody
        }
    }

    // MARK: - Markers

    private var markersBody: some View {
        Group {
            if test.markers.isEmpty {
                Text(isRU ? "Нет сохранённых маркеров." : "No markers saved.")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(test.markers) { marker in
                        markerRow(marker)
                        Divider()
                    }
                }
            }
        }
    }

    private func markerRow(_ marker: LabMarker) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(marker.name).font(.headline)
                    if let ref = marker.referenceRange, !ref.isEmpty {
                        Text(isRU ? "Норма: \(ref)" : "Reference: \(ref)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 4) {
                    // Sprint 4.7x: color the value based on flag.
                    // Apply foregroundColor on the WHOLE HStack (not just the
                    // Text) — SwiftUI on iOS 17/18 has a bug where
                    // .foregroundColor on Text().fontWeight(.bold) is silently
                    // dropped. Wrapping the row in a foregroundColor-modifier
                    // forces the color through.
                    HStack(spacing: 4) {
                        Text(marker.value).fontWeight(.bold)
                        Text(marker.unit ?? "").foregroundColor(.secondary)
                    }
                    .foregroundColor(marker.flag.flatMap(flagColor(for:)) ?? .primary)
                }
            }
            if let flag = marker.flag, !flag.isEmpty {
                HStack {
                    Spacer()
                    Text(flag)
                        .font(.caption).fontWeight(.semibold)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(flagColor(for: flag))
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Prescriptions

    private var prescriptionsBody: some View {
        Group {
            if test.prescriptions.isEmpty {
                Text(isRU ? "Нет назначений." : "No medications saved.")
                    .foregroundColor(.secondary)
                    .italic()
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(test.prescriptions) { med in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(med.name).font(.headline)
                            HStack(spacing: 12) {
                                if let dose = med.dose, !dose.isEmpty {
                                    Label(dose, systemImage: "pills").font(.caption)
                                }
                                if let freq = med.frequency, !freq.isEmpty {
                                    Label(freq, systemImage: "clock").font(.caption)
                                }
                                if let dur = med.duration, !dur.isEmpty {
                                    Label(dur, systemImage: "calendar").font(.caption)
                                }
                                if let route = med.route, !route.isEmpty {
                                    Label(route, systemImage: "arrow.right").font(.caption)
                                }
                            }
                            .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.systemGray6))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
        }
    }

    // MARK: - Structured fields

    private var structuredBody: some View {
        Group {
            if test.structuredFields.isEmpty {
                if !test.rawText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(isRU ? "Сырой текст:" : "Raw text:")
                            .font(.subheadline.bold())
                        Text(test.rawText)
                            .font(.body)
                            .foregroundColor(.primary)
                            .padding()
                            .background(Color(.systemGray6))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                } else {
                    Text(isRU ? "Нет сохранённых разделов." : "No sections saved.")
                        .foregroundColor(.secondary)
                        .italic()
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(test.structuredFields.sorted(by: { $0.order < $1.order })) { field in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(field.key)
                                .font(.headline)
                                .foregroundColor(.accentColor)
                            Text(field.value)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.systemGray6))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            }
        }
    }

    private func flagColor(for flag: String) -> Color {
        switch flag.lowercased() {
        case "high": return .red
        case "low": return .orange
        case "normal": return .green
        default: return .gray
        }
    }
}
