import SwiftUI
import SwiftData

@main
struct SomaAIApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
            // Temporarily disabling modelContainer to isolate the crash
            // .modelContainer(for: [UserProfile.self, LabTest.self, LabMarker.self, Medication.self, HealthEvent.self, Allergy.self, Condition.self])
        }
    }
}
