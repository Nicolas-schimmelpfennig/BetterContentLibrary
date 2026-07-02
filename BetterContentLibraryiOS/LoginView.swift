//
//  LoginView.swift
//  BetterContentLibrary (iOS)
//

import SwiftUI
import BetterContentCore

/// Email/password sign-in and sign-up. On sign-up the display name and org name
/// ride along as metadata so the backend trigger creates the org + owner profile.
struct LoginView: View {
    @Environment(AuthService.self) private var auth

    @State private var isSignUp = false
    @State private var email = ""
    @State private var password = ""
    @State private var displayName = ""
    @State private var orgName = ""
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "film.stack")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                    .padding(.top, 60)

                Text(isSignUp ? "Create your account" : "Sign in")
                    .font(.largeTitle.bold())

                VStack(spacing: 12) {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(isSignUp ? .newPassword : .password)

                    if isSignUp {
                        TextField("Your name", text: $displayName)
                            .textContentType(.name)
                        TextField("Organization name", text: $orgName)
                    }
                }
                .textFieldStyle(.roundedBorder)

                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }

                Button(action: submit) {
                    if isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(isSignUp ? "Sign up" : "Sign in").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isWorking || email.isEmpty || password.isEmpty)

                Button(isSignUp ? "Already have an account? Sign in"
                                : "No account? Create one") {
                    withAnimation { isSignUp.toggle() }
                    errorMessage = nil
                }
                .font(.callout)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
    }

    private func submit() {
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if isSignUp {
                    try await auth.signUp(
                        email: email,
                        password: password,
                        displayName: displayName.isEmpty ? nil : displayName,
                        orgName: orgName.isEmpty ? nil : orgName
                    )
                } else {
                    try await auth.signIn(email: email, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
