import SwiftUI

struct SettingsView: View {
    @AppStorage("api_base_url") private var apiBaseURL = "http://localhost:3000"
    @StateObject private var hkManager = HKManager.shared

    var body: some View {
        Form {
            Section("API Server") {
                TextField("Base URL", text: $apiBaseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onChange(of: apiBaseURL) {
                        if let url = URL(string: apiBaseURL) {
                            Task {
                                await APIClient.shared.setBaseURL(url)
                            }
                        }
                    }
            }

            Section("HealthKit") {
                HStack {
                    Text("Available")
                    Spacer()
                    Text(hkManager.isAvailable ? "Yes" : "No")
                        .foregroundStyle(hkManager.isAvailable ? .green : .red)
                }

                HStack {
                    Text("Authorized")
                    Spacer()
                    Text(hkManager.isAuthorized ? "Yes" : "Pending")
                        .foregroundStyle(hkManager.isAuthorized ? .green : .secondary)
                }

                Button("Request Authorization") {
                    Task { await hkManager.requestAuthorization() }
                }
                .disabled(hkManager.isAuthorized)
            }

            Section("Account") {
                NavigationLink("Login / Register", destination: AuthView())
            }
        }
        .navigationTitle("Settings")
    }
}

#Preview {
    NavigationStack {
        SettingsView()
    }
}
