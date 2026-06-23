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
        // Ensuring the TabView respects safe areas across all device sizes
        .edgesIgnoringSafeArea(.all) 
    }
}

struct ProfileView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                Text("User Profile Interface")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Soma Profile")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct LabVaultView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                Text("Medical Records Archive")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Lab Vault")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct BrainView: View {
    var body: some View {
        NavigationStack {
            VStack {
                Spacer()
                Text("AI Consultant Interface")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Soma Brain")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
