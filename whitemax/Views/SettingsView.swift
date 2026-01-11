//
//  SettingsView.swift
//  whitemax
//

import SwiftUI

struct SettingsView: View {
    @StateObject private var service = MaxClientService.shared

    @State private var isClearing: Bool = false

    var body: some View {
        Form {
            Section("Организация") {
                NavigationLink("Папки") {
                    FoldersView()
                }
                NavigationLink("Вступить по ссылке") {
                    JoinByLinkView()
                }
            }

            Section("Данные") {
                Button(role: .destructive) {
                    clearLocalCache()
                } label: {
                    if isClearing {
                        Label("Очистка…", systemImage: "trash")
                    } else {
                        Label("Очистить локальный кэш", systemImage: "trash")
                    }
                }
                .disabled(isClearing)
            }

            Section("Аккаунт") {
                NavigationLink("Профиль") {
                    ProfileView()
                }
            }
        }
        .navigationTitle("Настройки")
    }

    private func clearLocalCache() {
        isClearing = true
        Task {
            defer { Task { @MainActor in isClearing = false } }

            service.stopEventMonitoring()
            // Best-effort: remove events dir in Documents/max_cache/events
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            let events = docs?.appendingPathComponent("max_cache/events", isDirectory: true)
            if let events {
                try? fm.removeItem(at: events)
            }
        }
    }
}

