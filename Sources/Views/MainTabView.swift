import SwiftUI
import SwiftData

struct MainTabView: View {
    @State private var currentLanguage: String = "English"

    var body: some View {
        TabView {
            ProfileView(language: $currentLanguage)
                .tabItem {
                    Label(Localization.somaTranslate("tab_profile", language: currentLanguage), systemImage: "person.fill")
                }

            LabVaultView(language: currentLanguage)
                .tabItem {
                    Label(Localization.somaTranslate("tab_vault", language: currentLanguage), systemImage: "folder.fill")
                }

            BrainView(language: currentLanguage)
                .tabItem {
                    Label(Localization.somaTranslate("tab_brain", language: currentLanguage), systemImage: "brain.head.profile")
                }
        }
        .environment(\.locale, .init(identifier: currentLanguage == "Русский" ? "ru" : "en"))
    }
}
