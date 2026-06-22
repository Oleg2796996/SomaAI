import Foundation
import SwiftData

@Model
final class UserProfile {
    var id: UUID = UUID()
    var fullName: String
    var birthDate: Date
    var gender: String
    var bloodType: String?
    var height: Double?
    var weight: Double?
    @Relationship(deleteRule: .cascade) var allergies: [Allergy] = []
    @Relationship(deleteRule: .cascade) var chronicConditions: [Condition] = []
    init(fullName: String, birthDate: Date, gender: String) {
        self.fullName = fullName
        self.birthDate = birthDate
        self.gender = gender
    }
}

@Model
final class LabTest {
    var id: UUID = UUID()
    var date: Date
    var provider: String 
    var testName: String 
    var sampleType: String? 
    var method: String?
    @Relationship(deleteRule: .cascade) var markers: [LabMarker] = []
    init(date: Date, provider: String, testName: String, sampleType: String? = nil, method: String? = nil) {
        self.date = date
        self.provider = provider
        self.testName = testName
        self.sampleType = sampleType
        self.method = method
    }
}

@Model
final class LabMarker {
    var id: UUID = UUID()
    var name: String        
    var loincCode: String?  
    var value: String       
    var unit: String?       
    var referenceRange: String? 
    var flag: String?       
    var isCritical: Bool = false 
    init(name: String, value: String, unit: String? = nil, loincCode: String? = nil, isCritical: Bool = false) {
        self.name = name
        self.value = value
        self.unit = unit
        self.loincCode = loincCode
        self.isCritical = isCritical
    }
}

@Model
final class Medication {
    var id: UUID = UUID()
    var name: String
    var dosage: String
    var frequency: String 
    var startDate: Date
    var endDate: Date?
    var purpose: String?   
    var isActive: Bool = true
    init(name: String, dosage: String, frequency: String, startDate: Date) {
        self.name = name
        self.dosage = dosage
        self.frequency = frequency
        self.startDate = startDate
    }
}

@Model
final class HealthEvent {
    var id: UUID = UUID()
    var date: Date
    var type: EventType 
    var title: String
    var eventDetails: String
    var intensity: Int? 
    var provider: String? 
    init(date: Date, type: EventType, title: String, eventDetails: String) {
        self.date = date
        self.type = type
        self.title = title
        self.eventDetails = eventDetails
    }
}

enum EventType: String, Codable {
    case symptom = "Symptom"
    case visit = "Visit"
    case surgery = "Surgery"
}

@Model
final class Allergy {
    var id: UUID = UUID()
    var substance: String
    var reaction: String
    var severity: String 
    init(substance: String, reaction: String, severity: String) {
        self.substance = substance
        self.reaction = reaction
        self.severity = severity
    }
}

@Model
final class Condition {
    var id: UUID = UUID()
    var name: String
    var diagnosedDate: Date
    var status: String 
    init(name: String, diagnosedDate: Date, status: String) {
        self.name = name
        self.diagnosedDate = diagnosedDate
        self.status = status
    }
}
