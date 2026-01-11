//
//  MessageSearchView.swift
//  whitemax
//

import SwiftUI

struct MessageSearchView: View {
    @StateObject private var service = MaxClientService.shared
    @StateObject private var index = MaxClientService.shared.messageIndex

    @State private var query: String = ""
    @State private var results: [MessageSearchHit] = []

    @State private var isIndexing: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                HStack {
                    Text("Проиндексировано: \(index.indexedChatsCount()) чатов, \(index.indexedMessagesCount()) сообщений")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                Button {
                    Task { await buildIndexForAllChats() }
                } label: {
                    if isIndexing {
                        Label("Индексирование…", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("Проиндексировать последние 50 сообщений", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(isIndexing)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

            }

            Section("Результаты") {
                if results.isEmpty && !query.isEmpty {
                    ContentUnavailableView(
                        "Ничего не найдено",
                        systemImage: "magnifyingglass",
                        description: Text("Попробуйте другой запрос.")
                    )
                } else {
                    ForEach(results) { hit in
                        if let chat = service.chatsCache[hit.chatId] {
                            NavigationLink {
                                MessagesView(chat: chat, initialScrollToMessageId: hit.messageId)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(chat.title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)

                                    Text(hit.messageText)
                                        .lineLimit(2)

                                    if let ts = hit.timestamp {
                                        Text(Self.formatTime(ts))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } else {
                            // Chat not in cache (e.g. user didn't load chats list yet)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Chat \(hit.chatId)")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(hit.messageText)
                                    .lineLimit(2)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
        }
        .navigationTitle("Поиск по сообщениям")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Текст сообщения")
        .onChange(of: query) { _, newValue in
            results = index.search(newValue)
        }
    }

    private func buildIndexForAllChats() async {
        isIndexing = true
        errorMessage = nil
        defer { isIndexing = false }

        // Need chats list for indexing; if empty, try to load
        if service.chatsCache.isEmpty {
            do {
                _ = try await service.getChats()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        let chatIds = service.chatsCache.keys.sorted()
        for chatId in chatIds {
            do {
                _ = try await service.getMessages(chatId: chatId, limit: 50)
            } catch {
                // best-effort: skip failures
                errorMessage = "Некоторые чаты не удалось проиндексировать (например, каналы/права доступа)."
                continue
            }
        }

        results = index.search(query)
    }

    private static func formatTime(_ timestampMs: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000.0)
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

