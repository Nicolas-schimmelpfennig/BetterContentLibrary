//
//  LoginView.swift
//  BetterContentLibrary
//
//  The one place the full brand appears — a fixed splash, not a document
//  window (design 1b). Email/password sign-in and sign-up; on sign-up the
//  display name and org name ride as metadata for the backend trigger.
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
        VStack(spacing: 0) {
            Spacer()

            BrandMark(size: 76)

            Text("BetterContentLibrary")
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(BCLTheme.textPrimary)
                .padding(.top, 18)
            Text("From final cut to posted.")
                .font(.system(size: 12.5))
                .foregroundStyle(BCLTheme.textSecondary)
                .padding(.top, 5)

            VStack(spacing: 10) {
                field("Email", text: $email, contentType: .emailAddress)
                secureField("Password", text: $password)

                if isSignUp {
                    field("Your name", text: $displayName, contentType: .name)
                    field("Organization name", text: $orgName, contentType: nil)
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 11.5))
                        .foregroundStyle(BCLTheme.errorText)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }

                Button(action: submit) {
                    Group {
                        if isWorking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(isSignUp ? "Create Account" : "Sign In")
                                .font(.system(size: 13, weight: .semibold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
                    .background(BCLTheme.accent, in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
                }
                .buttonStyle(.plain)
                .disabled(isWorking || email.isEmpty || password.isEmpty)
                .opacity(email.isEmpty || password.isEmpty ? 0.5 : 1)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)

                Button(isSignUp ? "Already have an account? Sign in"
                                : "No account? Create one") {
                    withAnimation { isSignUp.toggle() }
                    errorMessage = nil
                }
                .buttonStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundStyle(BCLTheme.textLabel)
                .padding(.top, 2)
            }
            .frame(width: 300)
            .padding(.top, 28)
            .disabled(isWorking)

            Spacer()

            Text("Signed-in devices manage one library per organization")
                .font(.system(size: 10.5))
                .foregroundStyle(BCLTheme.textPrimary.opacity(0.3))
                .padding(.bottom, 18)
        }
        .frame(minWidth: 760, minHeight: 520)
        .background(BCLTheme.sidebar)
    }

    private func field(_ placeholder: String, text: Binding<String>, contentType: NSTextContentType?) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .textContentType(contentType)
            .font(.system(size: 13))
            .foregroundStyle(BCLTheme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color(hex: 0x1F1F25), in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusControl).strokeBorder(BCLTheme.border, lineWidth: 1))
    }

    private func secureField(_ placeholder: String, text: Binding<String>) -> some View {
        SecureField(placeholder, text: text)
            .textFieldStyle(.plain)
            .textContentType(.password)
            .font(.system(size: 13))
            .foregroundStyle(BCLTheme.textPrimary)
            .padding(.horizontal, 11)
            .frame(height: 34)
            .background(Color(hex: 0x1F1F25), in: RoundedRectangle(cornerRadius: BCLTheme.radiusControl))
            .overlay(RoundedRectangle(cornerRadius: BCLTheme.radiusControl).strokeBorder(BCLTheme.border, lineWidth: 1))
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
