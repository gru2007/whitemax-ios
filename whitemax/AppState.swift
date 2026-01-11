//
//  AppState.swift
//  whitemax
//
//  Глобальное состояние приложения
//

import Foundation
import SwiftUI
import Combine

@MainActor
class AppState: ObservableObject {
    @Published var isAuthenticated = false
    @Published var isLoading = true
    
    private let service = MaxClientService.shared
    private var cancellables = Set<AnyCancellable>()
    
    init() {
        // Следим за изменениями авторизации в сервисе, чтобы root UI всегда переключался
        // после логина/логаута (без хрупких onChange в ContentView).
        service.$isAuthenticated
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newValue in
                self?.isAuthenticated = newValue
            }
            .store(in: &cancellables)

        checkAuthentication()
    }
    
    func checkAuthentication() {
        isLoading = true
        
        Task {
            // Проверяем наличие токена
            let hasToken = service.checkAuthentication()
            
            if hasToken {
                // Пытаемся запустить клиент и восстановить сессию
                do {
                    try await service.startClient()
                    try? await service.startEventMonitoring()
                    isAuthenticated = service.isAuthenticated
                } catch {
                    print("Failed to start client: \(error)")
                    // Если не удалось восстановить сессию, очищаем токен
                    UserDefaults.standard.removeObject(forKey: "max_auth_token")
                    isAuthenticated = false
                }
            } else {
                isAuthenticated = false
                service.stopEventMonitoring()
            }
            
            isLoading = false
        }
    }
    
    func setAuthenticated(_ value: Bool) {
        isAuthenticated = value
    }
}
