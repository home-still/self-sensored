import SwiftUI

struct AuthView: View {
    @State private var email = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    var body: some View {
        Form {
            Section {
                TextField("Email", text: $email)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.emailAddress)

                SecureField("Password", text: $password)
            }

            Section {
                Button(isRegistering ? "Register" : "Login") {
                    Task { await authenticate() }
                }
                .disabled(email.isEmpty || password.isEmpty || isLoading)

                Toggle("Create new account", isOn: $isRegistering)
            }

            if isLoading {
                ProgressView()
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }

            if let success = successMessage {
                Section {
                    Text(success)
                        .foregroundStyle(.green)
                }
            }
        }
        .navigationTitle(isRegistering ? "Register" : "Login")
    }

    private func authenticate() async {
        isLoading = true
        errorMessage = nil
        successMessage = nil

        do {
            if isRegistering {
                _ = try await APIClient.shared.register(email: email, password: password)
                successMessage = "Registered successfully."
            } else {
                _ = try await APIClient.shared.login(email: email, password: password)
                successMessage = "Logged in."
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

#Preview {
    NavigationStack {
        AuthView()
    }
}
