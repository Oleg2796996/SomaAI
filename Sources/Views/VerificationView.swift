import SwiftUI

struct VerificationView: View {
    @Binding var markers: [SomaMarker]
    let language: String
    var onConfirm: ([SomaMarker]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if markers.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Ничего не распознано автоматически.")
                                .font(.headline)
                            Text("Вы можете добавить маркеры вручную — кнопка ниже. Заполните имя, значение и (по желанию) единицы измерения.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section(header: Text("Verify Recognized Markers")) {
                    ForEach($markers) { $marker in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField("Name", text: $marker.name)
                                    .frame(minWidth: 80)
                                TextField("Value", text: $marker.value)
                                    .frame(minWidth: 50)
                                TextField("Unit", text: Binding(
                                    get: { marker.unit ?? "" },
                                    set: { marker.unit = $0 }
                                ))
                                .frame(width: 60)
                            }
                            HStack {
                                TextField("Reference", text: Binding(
                                    get: { marker.referenceRange ?? "" },
                                    set: { marker.referenceRange = $0 }
                                ))
                                .frame(maxWidth: .infinity)
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
                    .onDelete { indexSet in
                        markers.remove(atOffsets: indexSet)
                    }
                }

                Section {
                    Button(action: {
                        let empty = SomaMarker(name: "", value: "", unit: nil, referenceRange: nil, flag: nil)
                        markers.append(empty)
                    }) {
                        Label("Add Marker", systemImage: "plus")
                    }
                }
            }
            .navigationTitle("Verify Data")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Confirm") {
                        onConfirm(markers)
                        dismiss()
                    }
                    .fontWeight(.bold)
                    .disabled(markers.allSatisfy { $0.name.isEmpty })
                }
            }
        }
    }
}
