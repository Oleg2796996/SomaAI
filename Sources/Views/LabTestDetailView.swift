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
        // 5d-ui-table: переписано на Grid с фиксированными
        // колонками. Идея:
        //   name        | value | unit | flag-pill
        //   (range)     |       |      |
        // Name = 2 строки, value = 1 строка (lineLimit 1, ellipsis),
        // unit = серая 1 строка, flag = компактный цветной pill
        // шириной ~60pt. Справа вертикальный стек unit+flag.
        let name = marker.name
        let value = marker.value
        let unit = marker.unit ?? ""
        let range = marker.referenceRange ?? ""
        let flag = marker.flag ?? ""
        return HStack(alignment: .center, spacing: 8) {
            // Name + range column (flexible, takes leftover)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.subheadline).fontWeight(.medium)
                    .lineLimit(1).truncationMode(.tail)
                if !range.isEmpty {
                    Text(range)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Value (single line, ellipsis, bold)
            Text(value)
                .font(.subheadline).fontWeight(.semibold)
                .lineLimit(1).truncationMode(.tail)
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(
                    Capsule().fill(
                        (marker.flag.flatMap(flagColor(for:)) ?? Color.red).opacity(0.22)
                    )
                )
                .frame(minWidth: 50, maxWidth: 110, alignment: .center)
            // Unit (single line, gray, narrow)
            if !unit.isEmpty {
                Text(unit)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(width: 40, alignment: .leading)
            } else {
                Spacer().frame(width: 40)
            }
            // Flag pill (compact, colored, 60pt)
            if !flag.isEmpty {
                Text(flag)
                    .font(.caption2).fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(width: 60, height: 22)
                    .background(flagColor(for: flag))
                    .clipShape(Capsule())
            } else {
                Spacer().frame(width: 60)
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
