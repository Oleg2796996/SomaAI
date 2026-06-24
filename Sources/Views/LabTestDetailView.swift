import SwiftUI

struct LabTestDetailView: View {
    let test: LabTest
    let language: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(test.testName)
                        .font(.title)
                        .fontWeight(.bold)
                    Text(test.provider)
                        .foregroundColor(.secondary)
                    Text(test.date, style: .date)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                if test.markers.isEmpty {
                    Text("No markers saved for this test.")
                        .foregroundColor(.secondary)
                        .italic()
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(test.markers) { marker in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(marker.name)
                                        .font(.headline)
                                    if let ref = marker.referenceRange, !ref.isEmpty {
                                        Text("Reference: \(ref)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Spacer()
                                HStack(spacing: 4) {
                                    Text(marker.value)
                                        .fontWeight(.bold)
                                    Text(marker.unit ?? "")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .padding(.vertical, 4)

                            if let flag = marker.flag, !flag.isEmpty {
                                HStack {
                                    Spacer()
                                    Text(flag)
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 2)
                                        .background(flagColor(for: flag))
                                        .foregroundColor(.white)
                                        .clipShape(Capsule())
                                }
                            }

                            Divider()
                        }
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

    private func flagColor(for flag: String) -> Color {
        switch flag.lowercased() {
        case "high": return .red
        case "low": return .orange
        case "normal": return .green
        default: return .gray
        }
    }
}
