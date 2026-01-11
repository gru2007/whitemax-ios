//
//  LoginView.swift
//  whitemax
//
//  Экран ввода номера телефона для авторизации
//

import SwiftUI

struct LoginView: View {
    @StateObject private var service = MaxClientService.shared
    @State private var phoneNumber = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showCodeVerification = false
    @State private var tempToken: String?
    
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.accentColor.opacity(0.22), Color(uiColor: .systemBackground)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay { Rectangle().fill(.ultraThinMaterial).opacity(0.55) }

            VStack(spacing: 18) {
                VStack(spacing: 8) {
                    Text("Вход в WhiteMax")
                        .font(.largeTitle.bold())
                    Text("Введите номер телефона, чтобы получить код авторизации")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 28)
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Номер телефона")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    TextField("+79991234567", text: $phoneNumber)
                        .keyboardType(.phonePad)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                        .liquidGlass(cornerRadius: 16, material: .thinMaterial)
                }
                .padding(.horizontal, 20)

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 20)
                }

                Button(action: requestCode) {
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("Отправить код")
                            .fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isLoading || phoneNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .padding(.horizontal, 20)

                Spacer(minLength: 0)
            }
        }
        .navigationDestination(isPresented: $showCodeVerification) {
            if let token = tempToken {
                CodeVerificationView(phoneNumber: phoneNumber, tempToken: token)
            }
        }
    }
    
    private func requestCode() {
        guard !phoneNumber.isEmpty else { return }
        
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                // Создаем wrapper для телефона
                try await service.createWrapper(phone: phoneNumber)
                
                // Запрашиваем код
                let token = try await service.requestCode(phone: phoneNumber)
                
                await MainActor.run {
                    self.tempToken = token
                    self.isLoading = false
                    self.showCodeVerification = true
                }
            } catch let error as MaxClientError {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = "Ошибка: \(error.localizedDescription)"
                    self.isLoading = false
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        LoginView()
    }
}
