import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.fill")
                }
            
            LabVaultView()
                .tabItem {
                    Label("Vault", systemImage: "folder.fill")
                }
            
            BrainView()
                .tabItem {
                    Label("Brain", systemImage: "brain.head.profile")
                }
        }
    }
}

struct ProfileView: View {
    var body: some View {
        NavigationStack {
            Text("User Profile Interface")
                .navigationTitle("Soma Profile")
        }
    }
}

struct LabVaultView: View {
    var body: some View {
        NavigationStack {
            Text("Medical Records Archive")
                .navigationTitle("Lab Vault")
        }
    }
}

struct BrainView: View {
    var body: some View {
        NavigationStack {
            Text("AI Consultant Interface")
                .navigationTitle("Soma Brain")
        }
    }
}
