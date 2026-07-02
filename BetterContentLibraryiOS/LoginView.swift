//
//  LoginView.swift
//  BetterContentLibrary (iOS)
//
//  Same brand block as the macOS login (design 1k); 44pt fields and buttons.
//  Email/password sign-in and sign-up; sign-up metadata drives the backend
//  org + owner-profile trigger.
//

import SwiftUI
import BetterContentCore

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
            VStack(spacing: 0) {
                BrandMark(size: 66)
                    .padding(.top, 90)

                Text("BetterContentLibrary")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(BCLTheme.textPrimary)
                    .padding(.top, 16)
                Text("From final cut to posted.")
                    .font(.system(size: 12))
                    .foregroundStyle(BCLTheme.textSecondary)
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    field("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    secureField("Password", text: $password)

                    if isSignUp {
                        field("Your name", text: $displayName)
                            .textContentType(.name)
                        field("Organization name", text: $orgName)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.system(size: 12))
                            .foregroundStyle(BCLTheme.errorText)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: submit) {
                        Group {
                            if isWorking {
                                ProgressView().tint(.white)
                            } else {
                                Text(isSignUp ? "Create Account" : "Sign In")
                                    .font(.system(size: 14.5, weight: .semibold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 46)
                        .background(BCLTheme.accent, in: RoundedRectangle(cornerRadius: 11))
                    }
                    .disabled(isWorking || email.isEmpty || password.isEmpty)
                    .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
                    .padding(.top, 6)

                    Button(isSignUp ? "Already have an account? Sign in"
                                    : "No account? Create one") {
                        withAnimation { isSignUp.toggle() }
                        errorMessage = nil
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(BCLTheme.textLabel)
                    .padding(.top, 4)
                }
                .padding(.top, 26)
                .disabled(isWorking)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .background(BCLTheme.well)
        .scrollBounceBehavior(.basedOnSize)
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(size: 14))
            .foregroundStyle(BCLTheme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textContentType(isSignUp ? .newPassword : .password)
            .font(.system(size: 14))
            .foregroundStyle(BCLTheme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(BCLTheme.content, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
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
