import SwiftUI

struct VerificationView: View {
    @Binding var markers: [SomaMarker]
    let language: String
    var onConfirm: ([SomaMarker]) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Verify Recognized Markers")) {
                    ForEach($markers) { $marker in
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
                }
            }
        }
    }
}
