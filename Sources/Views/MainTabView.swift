import SwiftUI

struct MainTabView: View {
    var body: some View {
        ZStack {
            // Background to force the app to fill the entire simulator screen
            Color(.systemBackground)
                .ignoresSafeArea()

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
            .ignoresSafeArea(.all, edges: .bottom) 
        }
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
            .background(Color(.systemBackground))
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
            .background(Color(.systemBackground))
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
            .background(Color(.systemBackground))
            .navigationTitle("Soma Brain")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
