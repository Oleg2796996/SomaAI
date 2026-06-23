import Foundation

enum AppLanguage: String, CaseIterable {
    case english = "English"
    case russian = "Русский"
}

struct Localization {
    static let strings: [String: [String: String]] = [
        "English": [
            "profile_title": "Soma Profile",
            "section_personal": "Personal Information",
            "field_name": "Full Name",
            "field_birthdate": "Birth Date",
            "field_gender": "Gender",
            "section_health": "Health Data",
            "field_blood": "Blood Type",
            "field_height": "Height (cm)",
            "field_weight": "Weight (kg)",
            "section_settings": "App Settings",
            "field_language": "UI Language",
            "button_save": "Save Profile"
        ],
        "Русский": [
            "profile_title": "Профиль Soma",
            "section_personal": "Личная информация",
            "field_name": "Полное имя",
            "field_birthdate": "Дата рождения",
            "field_gender": "Пол",
            "section_health": "Данные о здоровье",
            "field_blood": "Группа крови",
            "field_height": "Рост (см)",
            "field_weight": "Вес (кг)",
            "section_settings": "Настройки приложения",
            "field_language": "Язык интерфейса",
            "button_save": "Сохранить профиль"
        ]
    ]
    
    static func translate(_ key: String, language: String) -> String {
        let lang = AppLanguage(rawValue: language)?.rawValue ?? "English"
        return strings[lang]?[key] ?? key
    }
}
