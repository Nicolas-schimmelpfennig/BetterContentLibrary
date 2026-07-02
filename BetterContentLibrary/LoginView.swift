//
//  LoginView.swift
//  BetterContentLibrary
//

import SwiftUI
import BetterContentCore

/// Email/password sign-in and sign-up. On sign-up, the display name and
/// organization name are sent as metadata so the backend trigger can create
/// the org + owner profile.
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
        VStack(spacing: 16) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tint)

            Text(isSignUp ? "Create your account" : "Sign in")
                .font(.largeTitle.bold())

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                SecureField("Password", text: $password)
                    .textContentType(.password)

                if isSignUp {
                    TextField("Your name", text: $displayName)
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
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(isSignUp ? "Sign up" : "Sign in")
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isWorking || email.isEmpty || password.isEmpty)

            Button(isSignUp ? "Already have an account? Sign in"
                            : "No account? Create one") {
                withAnimation { isSignUp.toggle() }
                errorMessage = nil
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(40)
        .frame(width: 380)
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
