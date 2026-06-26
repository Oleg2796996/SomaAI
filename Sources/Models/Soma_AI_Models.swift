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

/// Document types SomaAI recognises. The classifier in SomaAPIClient
/// assigns one of these to every imported document.
enum DocumentType: String, Codable, CaseIterable {
    case labResult        // лабораторный анализ (кровь, моча, биохимия)
    case epicrisis        // выписка / эпикриз
    case prescription     // рецепт / назначения
    case referral         // направление на анализы / к врачу
    case consultation     // консультативное заключение
    case dischargeSummary // выписной эпикриз
    case imagingReport    // рентген / КТ / МРТ / УЗИ заключение
    case vaccination      // прививка / вакцинация
    case unknown          // не удалось определить

    var displayNameRU: String {
        switch self {
        case .labResult: return "Анализ"
        case .epicrisis: return "Эпикриз"
        case .prescription: return "Рецепт"
        case .referral: return "Направление"
        case .consultation: return "Консультация"
        case .dischargeSummary: return "Выписка"
        case .imagingReport: return "Снимок / УЗИ"
        case .vaccination: return "Вакцинация"
        case .unknown: return "Документ"
        }
    }
    var displayNameEN: String {
        switch self {
        case .labResult: return "Lab Result"
        case .epicrisis: return "Epicrisis"
        case .prescription: return "Prescription"
        case .referral: return "Referral"
        case .consultation: return "Consultation"
        case .dischargeSummary: return "Discharge"
        case .imagingReport: return "Imaging Report"
        case .vaccination: return "Vaccination"
        case .unknown: return "Document"
        }
    }
    var iconName: String {
        switch self {
        case .labResult: return "testtube.2"
        case .epicrisis: return "doc.text"
        case .prescription: return "pills"
        case .referral: return "arrow.right.doc"
        case .consultation: return "stethoscope"
        case .dischargeSummary: return "arrow.left.doc"
        case .imagingReport: return "rectangle.dashed.badge.record"
        case .vaccination: return "syringe"
        case .unknown: return "doc"
        }
    }
}

/// Universal medical document. Class name kept as LabTest for SwiftData
/// backward-compat (existing user data continues to load), but the
/// storage now covers all medical document types through the
/// documentType discriminator + polymorphic children (markers,
/// structuredFields, prescriptions).
@Model
final class LabTest {
    var id: UUID = UUID()
    var date: Date
    var provider: String
    var testName: String
    var sampleType: String?
    var method: String?

    // --- New universal-document fields ---
    /// Auto-detected by the LLM classifier. Defaults to labResult so
    /// pre-existing data is preserved without migration.
    var documentTypeRaw: String = DocumentType.labResult.rawValue
    /// Where the document came from (clinic, lab, hospital, doctor).
    /// Same as `provider` for lab results; for prescriptions / referrals
    /// this is the issuing institution.
    var organization: String?
    /// Original OCR text — always saved so the user can re-parse later.
    var rawText: String = ""
    /// 0.0–1.0, how confident the classifier + extractor were.
    var extractionConfidence: Double = 1.0
    /// Which LLM fields the user should double-check.
    var uncertainFields: [String] = []

    @Relationship(deleteRule: .cascade) var markers: [LabMarker] = []
    @Relationship(deleteRule: .cascade) var structuredFields: [DocumentField] = []
    @Relationship(deleteRule: .cascade) var prescriptions: [PrescribedMed] = []

    /// SwiftData computed accessor — reads/writes the documentType
    /// through its raw string backing.
    var documentType: DocumentType {
        get { DocumentType(rawValue: documentTypeRaw) ?? .unknown }
        set { documentTypeRaw = newValue.rawValue }
    }

    init(
        date: Date,
        provider: String,
        testName: String,
        sampleType: String? = nil,
        method: String? = nil,
        documentType: DocumentType = .labResult,
        organization: String? = nil,
        rawText: String = "",
        extractionConfidence: Double = 1.0
    ) {
        self.date = date
        self.provider = provider
        self.testName = testName
        self.sampleType = sampleType
        self.method = method
        self.documentTypeRaw = documentType.rawValue
        self.organization = organization
        self.rawText = rawText
        self.extractionConfidence = extractionConfidence
    }
}

/// Type alias for readability. The class is still called `LabTest`
/// for SwiftData schema compatibility, but at the call site we use
/// `MedicalDocument` to signal the universal-document intent.
typealias MedicalDocument = LabTest

/// Flat, DB-agnostic projection of a MedicalDocument used by the
/// AI assistant (Brain) and by the polymorphic VerificationView.
/// `MedicalDocumentBuilder` constructs this from a `LabTest`.
struct BrainContext: Codable {
    let documentId: UUID
    let documentType: DocumentType
    let documentDate: Date
    let title: String
    let summary: String
    let fragments: [BrainFragment]
    /// Overall extraction confidence, 0.0–1.0.
    let confidence: Double
}

/// A single piece of extracted information from a medical document.
/// `BrainContext` is a flat list of these — markers, prescribed meds,
/// clinical notes and administrative data all share one shape.
struct BrainFragment: Codable, Identifiable {
    var id: UUID = UUID()
    let key: String
    let value: String
    let unit: String?
    let referenceRange: String?
    let flag: String?
    let category: FragmentCategory
    /// 0.0–1.0, per-fragment confidence. Brain filters out
    /// fragments below `0.5` to prevent hallucinated answers.
    let confidence: Double
}

enum FragmentCategory: String, Codable {
    case marker          // lab measurement (e.g. "Гемоглобин = 140 г/л")
    case medication      // prescribed drug (e.g. "Цефазолин 2,0")
    case clinicalNote    // diagnosis, complaint, recommendation
    case administrative  // clinic name, doctor, date
}

/// (epicrisis, consultation, referral, discharge summary).
@Model
final class DocumentField {
    var id: UUID = UUID()
    var key: String
    var value: String
    var order: Int = 0
    init(key: String, value: String, order: Int = 0) {
        self.key = key
        self.value = value
        self.order = order
    }
}

/// A single medication line on a prescription or epicrisis.
@Model
final class PrescribedMed {
    var id: UUID = UUID()
    var name: String
    var dose: String?
    var frequency: String?
    var duration: String?
    var route: String?
    init(name: String, dose: String? = nil, frequency: String? = nil, duration: String? = nil, route: String? = nil) {
        self.name = name
        self.dose = dose
        self.frequency = frequency
        self.duration = duration
        self.route = route
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
    init(
        name: String,
        value: String,
        unit: String? = nil,
        referenceRange: String? = nil,
        flag: String? = nil,
        loincCode: String? = nil,
        isCritical: Bool = false
    ) {
        self.name = name
        self.value = value
        self.unit = unit
        self.referenceRange = referenceRange
        self.flag = flag
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
            "button_save": "Process & Verify",
            "button_process_verify": "Process & Verify",
            "tab_profile": "Profile",
            "tab_vault": "Documents",
            "tab_brain": "Brain",
            "vault_empty_title": "No Documents",
            "vault_empty_desc": "No medical documents yet. Add your first one — analysis, epicrisis, prescription, anything!",
            "add_test_section": "Document Details",
            "field_test_name": "Document Title",
            "field_provider": "Organization",
            "field_date": "Document Date",
            "add_test_title": "New Medical Document",
            "test_detail_title": "Document Details",
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
            "button_save": "Обработать",
            "button_process_verify": "Обработать",
            "tab_profile": "Профиль",
            "tab_vault": "Документы",
            "tab_brain": "Мозг",
            "vault_empty_title": "Нет документов",
            "vault_empty_desc": "Мед. документов пока нет. Добавьте первый — анализ, эпикриз, рецепт, что угодно!",
            "add_test_section": "Детали документа",
            "field_test_name": "Название документа",
            "field_provider": "Организация",
            "field_date": "Дата документа",
            "add_test_title": "Новый мед. документ",
            "test_detail_title": "Детали документа",
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

/// Builds a flat `BrainContext` projection from a `MedicalDocument`.
/// Single entry point for Brain + VerificationView so we never have
/// to walk SwiftData relationships in the UI layer.
enum MedicalDocumentBuilder {
    static func context(from doc: MedicalDocument) -> BrainContext {
        var fragments: [BrainFragment] = []

        // Administrative fragments (always present)
        if !doc.provider.isEmpty {
            fragments.append(.init(key: "Организация", value: doc.provider, unit: nil, referenceRange: nil, flag: nil, category: .administrative, confidence: doc.extractionConfidence))
        }
        if let org = doc.organization, org != doc.provider, !org.isEmpty {
            fragments.append(.init(key: "Учреждение", value: org, unit: nil, referenceRange: nil, flag: nil, category: .administrative, confidence: doc.extractionConfidence))
        }

        // Markers (lab results)
        for m in doc.markers {
            fragments.append(.init(
                key: m.name,
                value: m.value,
                unit: m.unit,
                referenceRange: m.referenceRange,
                flag: m.flag,
                category: .marker,
                confidence: doc.extractionConfidence
            ))
        }

        // Prescriptions
        for p in doc.prescriptions {
            let value = [p.dose, p.frequency, p.duration]
                .compactMap { $0 }
                .joined(separator: ", ")
            fragments.append(.init(
                key: p.name,
                value: value.isEmpty ? "—" : value,
                unit: nil,
                referenceRange: nil,
                flag: nil,
                category: .medication,
                confidence: doc.extractionConfidence
            ))
        }

        // Structured fields (epicrisis / consultation)
        for f in doc.structuredFields.sorted(by: { $0.order < $1.order }) {
            fragments.append(.init(
                key: f.key,
                value: f.value,
                unit: nil,
                referenceRange: nil,
                flag: nil,
                category: .clinicalNote,
                confidence: doc.extractionConfidence
            ))
        }

        // Summary
        let markerCount = doc.markers.count
        let medCount = doc.prescriptions.count
        let fieldCount = doc.structuredFields.count
        let summary: String = {
            switch doc.documentType {
            case .labResult:
                return markerCount == 0 ? "Лабораторный анализ (без распознанных маркеров)"
                    : "Лабораторный анализ: \(markerCount) показател\(markerCount.ruPlural("ь","я","ей"))"
            case .prescription:
                return medCount == 0 ? "Рецепт / назначения"
                    : "Рецепт: \(medCount) препарат\(medCount.ruPlural("","а","ов"))"
            case .epicrisis, .consultation, .dischargeSummary:
                return fieldCount == 0 ? "Клинический документ"
                    : "Клинический документ: \(fieldCount) разделов"
            default:
                return doc.documentType.displayNameRU
            }
        }()

        return BrainContext(
            documentId: doc.id,
            documentType: doc.documentType,
            documentDate: doc.date,
            title: doc.testName,
            summary: summary,
            fragments: fragments,
            confidence: doc.extractionConfidence
        )
    }
}

private extension Int {
    /// Russian pluralisation: 1 показатель, 2 показателя, 5 показателей
    func ruPlural(_ one: String, _ few: String, _ many: String) -> String {
        let mod10 = self % 10
        let mod100 = self % 100
        if mod10 == 1 && mod100 != 11 { return one }
        if mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14) { return few }
        return many
    }
}
