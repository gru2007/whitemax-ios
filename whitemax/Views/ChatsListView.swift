//
//  ChatsListView.swift
//  whitemax
//
//  Список чатов
//

import SwiftUI

struct ChatsListView: View {
    @StateObject private var service = MaxClientService.shared
    @State private var chats: [MaxChat] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText: String = ""
    
    var body: some View {
        NavigationStack {
            ZStack {
                background
                    .ignoresSafeArea()

                Group {
                    if isLoading {
                        ProgressView("Загрузка чатов…")
                            .padding()
                            .liquidGlass(cornerRadius: 16)
                    } else if let error = errorMessage {
                        ContentUnavailableView(
                            "Не удалось загрузить чаты",
                            systemImage: "wifi.exclamationmark",
                            description: Text(error)
                        )
                        .padding()
                        .overlay(alignment: .bottom) {
                            Button("Повторить") { loadChats() }
                                .buttonStyle(.borderedProminent)
                                .padding(.bottom, 24)
                        }
                    } else if filteredChats.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "Нет чатов" : "Ничего не найдено",
                            systemImage: searchText.isEmpty ? "bubble.left.and.bubble.right" : "magnifyingglass",
                            description: Text(searchText.isEmpty ? "Начните переписку — и здесь появится список." : "Попробуйте другой запрос.")
                        )
                        .padding()
                    } else {
                        List {
                            ForEach(filteredChats) { chat in
                                NavigationLink(destination: MessagesView(chat: chat)) {
                                    ChatRow(chat: chat)
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .listStyle(.insetGrouped)
                        .refreshable {
                            await loadChatsAsync()
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: isLoading)
            }
            .navigationTitle("Чаты")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        NavigationLink {
                            GlobalSearchView()
                        } label: {
                            Label("Глобальный поиск", systemImage: "magnifyingglass")
                        }

                        NavigationLink {
                            MessageSearchView()
                        } label: {
                            Label("Поиск по сообщениям", systemImage: "text.magnifyingglass")
                        }

                        NavigationLink {
                            SettingsView()
                        } label: {
                            Label("Настройки", systemImage: "gearshape")
                        }

                        Button(role: .destructive) {
                            logout()
                        } label: {
                            Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .imageScale(.large)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
        }
        .task {
            await loadChatsAsync()
            // Enable real-time chat updates (best-effort)
            try? await service.startEventMonitoring()
        }
        .onChange(of: service.chatUpdates.count) { _ in
            guard let last = service.chatUpdates.last else { return }
            if let idx = chats.firstIndex(where: { $0.id == last.id }) {
                chats[idx] = last
            } else {
                chats.insert(last, at: 0)
            }
        }
    }

    private var filteredChats: [MaxChat] {
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return chats
        }
        let q = searchText.lowercased()
        return chats.filter { $0.title.lowercased().contains(q) }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.25),
                Color(uiColor: .systemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Rectangle().fill(.ultraThinMaterial).opacity(0.65)
        }
    }
    
    private func loadChats() {
        Task {
            await loadChatsAsync()
        }
    }
    
    private func loadChatsAsync() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let loadedChats = try await service.getChats()
            await MainActor.run {
                self.chats = loadedChats
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func logout() {
        Task {
            do {
                try await service.logout()
                // Навигация обратно к экрану входа будет обработана через AppState
            } catch {
                print("Logout error: \(error)")
            }
        }
    }
}

struct ChatRow: View {
    let chat: MaxChat
    
    var body: some View {
        HStack(spacing: 12) {
            AvatarView(title: chat.title, iconUrl: chat.iconUrl)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(chat.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if let ts = chat.lastMessageTime {
                        Text(Self.formatTime(ts))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    Label(chatTypeLabel, systemImage: chatTypeIcon)
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    if chat.unreadCount > 0 {
                        Text("\(chat.unreadCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.red, in: Capsule(style: .continuous))
                    }
                }
            }
        }
        .padding(.vertical, 6)
    }

    private var chatTypeLabel: String {
        switch chat.type.uppercased() {
        case "DIALOG": return "Диалог"
        case "CHAT": return "Группа"
        case "CHANNEL": return "Канал"
        default: return chat.type
        }
    }

    private var chatTypeIcon: String {
        switch chat.type.uppercased() {
        case "DIALOG": return "person.crop.circle"
        case "CHAT": return "person.2.circle"
        case "CHANNEL": return "megaphone"
        default: return "bubble.left.and.bubble.right"
        }
    }

    private static func formatTime(_ timestampMs: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private struct AvatarView: View {
    let title: String
    let iconUrl: String?

    var body: some View {
        ZStack {
            if let iconUrl, let url = URL(string: iconUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        }
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Text(String(title.prefix(1)).uppercased())
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
    }
}

#Preview {
    ChatsListView()
}
