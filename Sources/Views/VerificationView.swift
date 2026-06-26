import SwiftUI

/// Polymorphic verification screen. Adapts to whatever DocumentType
/// the 3-step pipeline detected (or to `.unknown` if nothing was
/// recognised). User can edit every field, add new ones, and the
/// final document is saved as a `MedicalDocument` (LabTest) with the
/// correct documentType + the right child relationships.
struct VerificationView: View {
    @Binding var documentType: DocumentType
    let pendingExtraction: SomaExtractionResponse?

    @Binding var markers: [SomaMarker]
    @Binding var medications: [SomaMedication]
    @Binding var sections: [SomaSection]

    @Binding var testName: String
    @Binding var provider: String
    @Binding var documentDate: Date

    let language: String
    var onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showConfidence = false

    private var isRU: Bool { language == "Русский" || language == "Russian" }

    private var titleKey: String {
        switch documentType {
        case .labResult: return "verify_title_lab"
        case .prescription: return "verify_title_prescription"
        case .epicrisis, .dischargeSummary, .consultation: return "verify_title_clinical"
        case .referral: return "verify_title_referral"
        case .imagingReport: return "verify_title_imaging"
        case .vaccination: return "verify_title_vaccination"
        case .unknown: return "verify_title_unknown"
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // ---- Header: doc type + organisation + confidence ----
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: documentType.iconName)
                            .font(.title2)
                            .foregroundColor(.accentColor)
                            .frame(width: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(documentType.displayNameRU)
                                .font(.headline)
                            if let org = provider.isEmpty ? nil : provider {
                                Text(org)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if let conf = pendingExtraction?.confidence {
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption2)
                                        .foregroundColor(conf >= 0.7 ? .green : .orange)
                                    Text(isRU
                                         ? "Уверенность: \(Int(conf * 100))%"
                                         : "Confidence: \(Int(conf * 100))%")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }

                // ---- Universal: title + date + organisation ----
                Section(isRU ? "Название и дата" : "Title & Date") {
                    TextField(isRU ? "Название документа" : "Document title", text: $testName)
                    DatePicker(isRU ? "Дата" : "Date", selection: $documentDate, displayedComponents: .date)
                    TextField(isRU ? "Организация" : "Organisation", text: $provider)
                }

                // ---- Type-specific body ----
                switch documentType {
                case .labResult:
                    labResultBody
                case .prescription:
                    prescriptionBody
                case .epicrisis, .dischargeSummary, .consultation, .referral, .imagingReport, .vaccination:
                    structuredFieldsBody
                case .unknown:
                    unknownBody
                }

                // ---- Empty-state hint for low-confidence cases ----
                if let conf = pendingExtraction?.confidence, conf < 0.5 {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text(isRU
                                 ? "LLM не уверен в распознавании. Проверьте каждое поле или сохраните как есть."
                                 : "The LLM is not confident. Please verify every field or save as is.")
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle(isRU ? "Проверка" : titleKey)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(isRU ? "Отмена" : "Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isRU ? "Сохранить" : "Confirm") {
                        onConfirm()
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(!canConfirm)
                }
            }
        }
    }

    // MARK: - Type-specific bodies

    private var labResultBody: some View {
        Group {
            Section(header: Text(isRU ? "Маркеры (\(markers.count))" : "Markers (\(markers.count))")) {
                if markers.isEmpty {
                    Text(isRU
                         ? "Ничего не распознано автоматически. Добавьте маркеры вручную."
                         : "Nothing was recognised. Add markers manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach($markers) { $marker in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField(isRU ? "Имя" : "Name", text: $marker.name).frame(minWidth: 80)
                                TextField(isRU ? "Значение" : "Value", text: $marker.value).frame(minWidth: 50)
                                TextField(isRU ? "Ед." : "Unit", text: Binding(
                                    get: { marker.unit ?? "" },
                                    set: { marker.unit = $0 }
                                )).frame(width: 60)
                            }
                            HStack {
                                TextField(isRU ? "Норма" : "Reference", text: Binding(
                                    get: { marker.referenceRange ?? "" },
                                    set: { marker.referenceRange = $0 }
                                )).frame(maxWidth: .infinity)
                                Picker("Flag", selection: Binding(
                                    get: { marker.flag ?? "" },
                                    set: { marker.flag = $0.isEmpty ? nil : $0 }
                                )) {
                                    Text("—").tag("")
                                    Text("High").tag("High")
                                    Text("Low").tag("Low")
                                    Text("Normal").tag("Normal")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 110)
                            }
                            .font(.caption)
                        }
                    }
                    .onDelete { indexSet in markers.remove(atOffsets: indexSet) }
                }
            }
            Section {
                Button(action: {
                    markers.append(SomaMarker(name: "", value: "", unit: nil, referenceRange: nil, flag: nil))
                }) {
                    Label(isRU ? "Добавить маркер" : "Add Marker", systemImage: "plus")
                }
            }
        }
    }

    private var prescriptionBody: some View {
        Group {
            Section(header: Text(isRU ? "Препараты (\(medications.count))" : "Medications (\(medications.count))")) {
                if medications.isEmpty {
                    Text(isRU
                         ? "Препараты не распознаны. Добавьте вручную."
                         : "No medications recognised. Add manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach($medications) { $med in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(isRU ? "Препарат" : "Drug name", text: $med.name)
                            HStack {
                                TextField(isRU ? "Доза" : "Dose", text: Binding(
                                    get: { med.dose ?? "" },
                                    set: { med.dose = $0.isEmpty ? nil : $0 }
                                ))
                                TextField(isRU ? "Частота" : "Frequency", text: Binding(
                                    get: { med.frequency ?? "" },
                                    set: { med.frequency = $0.isEmpty ? nil : $0 }
                                ))
                                TextField(isRU ? "Длительность" : "Duration", text: Binding(
                                    get: { med.duration ?? "" },
                                    set: { med.duration = $0.isEmpty ? nil : $0 }
                                ))
                            }
                            .font(.caption)
                        }
                    }
                    .onDelete { indexSet in medications.remove(atOffsets: indexSet) }
                }
            }
            Section {
                Button(action: {
                    medications.append(SomaMedication(name: "", dose: nil, frequency: nil, duration: nil, route: nil))
                }) {
                    Label(isRU ? "Добавить препарат" : "Add Medication", systemImage: "plus")
                }
            }
        }
    }

    private var structuredFieldsBody: some View {
        Group {
            Section(header: Text(isRU ? "Разделы (\(sections.count))" : "Sections (\(sections.count))")) {
                if sections.isEmpty {
                    Text(isRU
                         ? "Документ распознан, но разделы пустые. Добавьте вручную."
                         : "Document was recognised but no sections extracted. Add manually.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach($sections) { $section in
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(isRU ? "Заголовок" : "Heading", text: $section.key)
                                .font(.subheadline.bold())
                            TextField(isRU ? "Текст" : "Body", text: $section.value, axis: .vertical)
                                .lineLimit(2...10)
                                .font(.caption)
                        }
                    }
                    .onDelete { indexSet in sections.remove(atOffsets: indexSet) }
                }
            }
            Section {
                Button(action: {
                    sections.append(SomaSection(key: isRU ? "Новый раздел" : "New section", value: "", order: sections.count))
                }) {
                    Label(isRU ? "Добавить раздел" : "Add Section", systemImage: "plus")
                }
            }
        }
    }

    private var unknownBody: some View {
        Group {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "questionmark.bubble")
                        .font(.title)
                        .foregroundColor(.secondary)
                    Text(isRU
                         ? "Не удалось определить тип документа автоматически."
                         : "Could not auto-detect the document type.")
                        .font(.headline)
                    Text(isRU
                         ? "Ниже — сырой текст из OCR. Отредактируйте или сохраните как есть."
                         : "Below is the raw OCR text. Edit it or save as is.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            // Raw OCR goes into a single, large editable text section.
            Section(header: Text(isRU ? "Сырой текст" : "Raw Text")) {
                if sections.isEmpty {
                    Text(isRU ? "Текст отсутствует" : "No text")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    TextField(isRU ? "Текст" : "Text", text: $sections[0].value, axis: .vertical)
                        .lineLimit(4...30)
                        .font(.body)
                }
            }
            // Let the user tag what kind of document they think this is
            // by picking a type from the menu. Falls back to .unknown.
            Section(header: Text(isRU ? "Тип документа" : "Document type")) {
                Picker(isRU ? "Тип" : "Type", selection: $documentType) {
                    ForEach(DocumentType.allCases, id: \.self) { dt in
                        Label(dt.displayNameRU, systemImage: dt.iconName).tag(dt)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Logic

    /// Confirm button is enabled when the user has entered at least
    /// one meaningful field — a marker name, a medication name, a
    /// section heading, or any non-empty title.
    private var canConfirm: Bool {
        if !testName.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        if markers.contains(where: { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return true }
        if medications.contains(where: { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { return true }
        if sections.contains(where: { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }) { return true }
        return false
    }
}
