import SwiftUI
import SwiftData

@main
struct SomaAIApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
                .modelContainer(for: [UserProfile.self, LabTest.self, LabMarker.self, Medication.self, HealthEvent.self, Allergy.self, Condition.self])
        }
    }
}
