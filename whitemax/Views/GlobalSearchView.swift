//
//  GlobalSearchView.swift
//  whitemax
//

import SwiftUI

struct GlobalSearchView: View {
    @StateObject private var service = MaxClientService.shared

    @State private var query: String = ""
    @State private var isSearching: Bool = false
    @State private var errorMessage: String?

    @State private var userResult: MaxUser?
    @State private var channelResult: MaxChat?

    var body: some View {
        Form {
            Section("Запрос") {
                TextField("+7999… или @channel", text: $query)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                Button {
                    search()
                } label: {
                    if isSearching {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Label("Искать", systemImage: "magnifyingglass")
                    }
                }
                .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            if let userResult {
                Section("Пользователь") {
                    NavigationLink(destination: PrivateChatLoaderView(user: userResult)) {
                        HStack {
                            Image(systemName: "person.crop.circle")
                                .imageScale(.large)
                            Text(userResult.firstName)
                            Spacer()
                            Text("#\(userResult.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let channelResult {
                Section("Канал") {
                    NavigationLink(destination: MessagesView(chat: channelResult)) {
                        HStack {
                            Image(systemName: "megaphone")
                                .imageScale(.large)
                            Text(channelResult.title)
                            Spacer()
                            Text("#\(channelResult.id)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Поиск")
    }

    private func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }

        isSearching = true
        errorMessage = nil
        userResult = nil
        channelResult = nil

        Task {
            defer { Task { @MainActor in isSearching = false } }
            do {
                if q.hasPrefix("+") {
                    let user = try await service.searchUserByPhone(q)
                    await MainActor.run { userResult = user }
                } else if q.hasPrefix("@") {
                    let ch = try await service.resolveChannelByName(q)
                    await MainActor.run { channelResult = ch }
                } else {
                    // fallback: try channel name
                    let ch = try await service.resolveChannelByName(q)
                    await MainActor.run { channelResult = ch }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

private struct PrivateChatLoaderView: View {
    let user: MaxUser
    @StateObject private var service = MaxClientService.shared
    @State private var chat: MaxChat?
    @State private var errorMessage: String?
    
    var body: some View {
        Group {
            if let chat = chat {
                MessagesView(chat: chat)
            } else if let errorMessage = errorMessage {
                ContentUnavailableView(
                    "Ошибка",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("Загрузка чата…")
            }
        }
        .task {
            do {
                let loadedChat = try await service.getPrivateChatWithUser(user)
                await MainActor.run {
                    chat = loadedChat
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
