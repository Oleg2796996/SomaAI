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
    var preferredLanguage: String = "English"
    
    @Relationship(deleteRule: .cascade) var allergies: [Allergy] = []
    @Relationship(deleteRule: .cascade) var chronicConditions: [Condition] = []
    @Relationship(deleteRule: .cascade) var weightHistory: [WeightEntry] = []
    
    init(fullName: String = "", birthDate: Date = Date(), gender: String = "Unknown", preferredLanguage: String = "English") {
        self.fullName = fullName
        self.birthDate = birthDate
        self.gender = gender
        self.preferredLanguage = preferredLanguage
    }
}

@Model
final class WeightEntry {
    var id: UUID = UUID()
    var date: Date
    var value: Double
    
    init(date: Date = Date(), value: Double) {
        self.date = date
        self.value = value
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
    var labStandardId: String?
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

struct Localization {
    static let strings: [String: [String: String]] = [
        "English": [
            "profile_title": "Soma Profile",
            "section_personal": "Personal Information",
            "field_name": "Full Name",
            "field_birthdate": "Birth Date",
            "field_gender": "Gender",
            "gender_male": "Male",
            "gender_female": "Female",
            "gender_other": "Other",
            "section_health": "Health Data",
            "field_blood": "Blood Type",
            "field_height": "Height (cm)",
            "field_weight": "Weight (kg)",
            "section_settings": "App Settings",
            "field_language": "UI Language",
            "button_save": "Save",
            "tab_profile": "Profile",
            "tab_vault": "Vault",
            "tab_brain": "Brain",
            "vault_empty_title": "No Tests",
            "vault_empty_desc": "No medical tests found. Add your first one!",
            "add_test_section": "Test Details",
            "field_test_name": "Test Name",
            "field_provider": "Provider/Lab",
            "field_date": "Test Date",
            "add_test_title": "New Analysis",
            "test_detail_title": "Test Details",
            "button_scan": "Scan Document",
            "button_camera": "Take Photo",
            "button_photos": "Scan Photos",
            "button_pdf": "Import PDF",
            "disclaimer_data_only": "For informational purposes only. This is not a diagnosis or medical advice. Consult a licensed physician.",
            "brain_input_placeholder": "Ask Soma AI...",
            "brain_disclaimer_footer": "This assistant organizes data; it does not diagnose. Consult a physician.",
            "error_no_context": "No matching records found. Add lab results first, or ask a general question.",
            "brain_welcome_message": "Ask me about your latest lab results, trends, or what to discuss with your doctor."
        ],
        "Русский": [
            "profile_title": "Профиль Soma",
            "section_personal": "Личная информация",
            "field_name": "Полное имя",
            "field_birthdate": "Дата рождения",
            "field_gender": "Пол",
            "gender_male": "Мужской",
            "gender_female": "Женский",
            "gender_other": "Другой",
            "section_health": "Данные о здоровье",
            "field_blood": "Группа крови",
            "field_height": "Рост (см)",
            "field_weight": "Вес (кг)",
            "section_settings": "Настройки приложения",
            "field_language": "Язык интерфейса",
            "button_save": "Сохранить",
            "tab_profile": "Профиль",
            "tab_vault": "Сейф",
            "tab_brain": "Мозг",
            "vault_empty_title": "Нет анализов",
            "vault_empty_desc": "Анализы не найдены. Добавьте первый тест!",
            "add_test_section": "Детали анализа",
            "field_test_name": "Название анализа",
            "field_provider": "Лаборатория",
            "field_date": "Дата анализа",
            "add_test_title": "Новый анализ",
            "test_detail_title": "Детали анализа",
            "button_scan": "Сканировать документ",
            "button_camera": "Сфотографировать",
            "button_photos": "Выбрать фото",
            "button_pdf": "Импорт PDF",
            "disclaimer_data_only": "Только для информации. Это не диагноз и не медицинская рекомендация. Обратитесь к врачу.",
            "brain_input_placeholder": "Спросите Soma AI...",
            "brain_disclaimer_footer": "Ассистент организует данные, но не ставит диагноз. Обратитесь к врачу.",
            "error_no_context": "Подходящих записей не найдено. Сначала добавьте анализы или задайте общий вопрос.",
            "brain_welcome_message": "Спросите меня о последних анализах, тенденциях или о чём обсудить с врачом."
        ]
    ]
    
    static func somaTranslate(_ key: String, language: String) -> String {
        let lang = (language == "Русский" || language == "English") ? language : "English"
        return strings[lang]?[key] ?? key
    }
}
