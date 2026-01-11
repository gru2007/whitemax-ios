//
//  MaxClientService.swift
//  whitemax
//
//  Swift сервис для работы с Max.RU через Python
//

import Foundation
import Combine
import PythonKit

@MainActor
class MaxClientService: ObservableObject {
    static let shared = MaxClientService()
    
    @Published var isInitialized = false
    @Published var isAuthenticated = false
    @Published var currentUser: MaxUser?
    @Published private(set) var myUserId: Int?
    @Published var pymaxAvailable = false

    // Real-time events from Python wrapper
    @Published var newMessages: [MaxMessage] = []
    @Published var updatedMessages: [MaxMessage] = []
    @Published var deletedMessageIds: [(chatId: Int, messageId: String)] = []
    @Published var reactionUpdates: [(chatId: Int, messageId: String, reaction: String?)] = []
    @Published var chatUpdates: [MaxChat] = []

    // Local caches for UX (no extra permissions; stored in memory only)
    @Published private(set) var chatsCache: [Int: MaxChat] = [:]
    let messageIndex = MessageIndex()
    
    private var wrapperModule: PythonObject?
    private var eventMonitor: EventMonitor?
    
    private init() {
        initializePython()
    }
    
    private func initializePython() {
        do {
            try PythonBridge.shared.initialize()
            
            // Проверяем наличие файла перед импортом
            guard let bundlePath = Bundle.main.resourcePath else {
                print("Failed to get bundle path")
                return
            }
            
            let wrapperPath = "\(bundlePath)/app/max_client_wrapper.py"
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: wrapperPath) {
                print("Error: max_client_wrapper.py not found at: \(wrapperPath)")
                return
            }
            
            // Пытаемся импортировать модуль с обработкой ошибок
            do {
                wrapperModule = try PythonBridge.shared.importModule("max_client_wrapper")
                isInitialized = true
                print("✓ max_client_wrapper module loaded successfully")
            } catch {
                print("Error importing max_client_wrapper: \(error)")
                // Продолжаем без модуля - может быть pymax не установлен
                print("Note: max_client_wrapper will not work until pymax is available")
                isInitialized = false
            }
        } catch {
            print("Failed to initialize Python: \(error)")
            if let error = error as? PythonBridgeError {
                print("Error details: \(error.localizedDescription)")
            }
        }
    }
    
    func createWrapper(phone: String, workDir: String? = nil, token: String? = nil) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }
        
        // Always anchor python work_dir to app Documents to avoid "~" resolving differently on iOS.
        let workDirValue: String? = {
            if let workDir { return workDir }
            let fm = FileManager.default
            let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            return docs?.appendingPathComponent("max_cache", isDirectory: true).path
        }()
        let tokenValue = token
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let workDirPython = workDirValue != nil ? PythonObject(workDirValue!) : PythonObject(Python.None)
            let tokenPython = tokenValue != nil ? PythonObject(tokenValue!) : PythonObject(Python.None)
            let result = module.create_wrapper(phone, workDirPython, tokenPython)
            return String(result) ?? "{}"
        }
        
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool else {
            throw MaxClientError.invalidResponse
        }
        
        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            if error.contains("pymax not available") {
                let details = json["details"] as? String
                let msg = details != nil ? "\(error)\n\n\(details!)" : error
                throw MaxClientError.wrapperCreationFailed(msg)
            }
            throw MaxClientError.wrapperCreationFailed(error)
        }
    }
    
    func requestCode(phone: String? = nil, language: String = "ru") async throws -> String {
        let phoneValue = phone
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            guard let module = self.wrapperModule else {
                return "{\"success\": false, \"error\": \"Module not initialized\"}"
            }

            let phonePython = phoneValue != nil ? PythonObject(phoneValue!) : PythonObject(Python.None)
            let result = module.request_code(phonePython, language)
            return String(result) ?? "{}"
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool else {
            throw MaxClientError.invalidResponse
        }
        
        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.requestCodeFailed(error)
        }
        
        guard let tempToken = json["temp_token"] as? String else {
            throw MaxClientError.missingToken
        }
        
        return tempToken
    }
    
    func loginWithCode(tempToken: String, code: String) async throws -> MaxUser {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }
        
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            guard let module = self.wrapperModule else {
                return "{\"success\": false, \"error\": \"Module not initialized\"}"
            }
            let result = module.login_with_code(tempToken, code)
            return String(result) ?? "{}"
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool else {
            throw MaxClientError.invalidResponse
        }
        
        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            if (json["requires_new_code"] as? Bool) == true {
                throw MaxClientError.loginFailed("\(error)\n\nЗапросите новый код и попробуйте снова.")
            }
            throw MaxClientError.loginFailed(error)
        }
        
        // Сохраняем токен и номер телефона
        if let token = json["token"] as? String {
            UserDefaults.standard.set(token, forKey: "max_auth_token")
            // Сохраняем номер телефона для восстановления сессии
            if let phone = json["phone"] as? String {
                UserDefaults.standard.set(phone, forKey: "max_phone_number")
            }
            isAuthenticated = true
        }
        
        // Парсим информацию о пользователе
        // me может быть nil, если пользователь еще не загружен, это нормально
        if let me = json["me"] as? [String: Any],
           let id = me["id"] as? Int {
            // first_name может быть пустой строкой, это нормально
            let firstName = me["first_name"] as? String ?? "User"
            let user = MaxUser(id: id, firstName: firstName)
            currentUser = user
            myUserId = id
            UserDefaults.standard.set(id, forKey: "max_user_id")
            return user
        }
        
        // Если me отсутствует, но токен сохранен, это не критическая ошибка
        // Просто не устанавливаем currentUser
        // Keep stable outgoing detection even if "me" isn't returned yet
        let savedId = UserDefaults.standard.object(forKey: "max_user_id") as? Int
        if let savedId {
            myUserId = savedId
        }
        return MaxUser(id: savedId ?? 0, firstName: "Unknown")
    }
    
    func getChats() async throws -> [MaxChat] {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }
        
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            guard let module = self.wrapperModule else {
                return "{\"success\": false, \"error\": \"Module not initialized\"}"
            }
            let result = module.get_chats()
            return String(result) ?? "{}"
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool else {
            throw MaxClientError.invalidResponse
        }
        
        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.getChatsFailed(error)
        }
        
        guard let chatsArray = json["chats"] as? [[String: Any]] else {
            return []
        }
        
        let chatsRaw = chatsArray.compactMap { (chatDict: [String: Any]) -> MaxChat? in
            guard let id = chatDict["id"] as? Int,
                  let title = chatDict["title"] as? String else {
                return nil
            }
            
            let type = chatDict["type"] as? String ?? "unknown"
            let photoId = chatDict["photo_id"] as? Int  // Для диалогов
            let iconUrl = chatDict["icon_url"] as? String  // Для чатов и каналов
            let unreadCount = chatDict["unread_count"] as? Int ?? 0
            
            return MaxChat(
                id: id,
                title: title,
                type: type,
                photoId: photoId,
                iconUrl: iconUrl,
                unreadCount: unreadCount
            )
        }
        
        // Defensive: backend/wrapper can occasionally return duplicates (same id).
        // Never crash here; keep the last occurrence.
        chatsCache = Dictionary(chatsRaw.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        
        // Also dedupe the list we return (keeps first seen order, replaces by last data).
        var seen = Set<Int>()
        var out: [MaxChat] = []
        for c in chatsRaw {
            if seen.contains(c.id) { continue }
            seen.insert(c.id)
            out.append(c)
        }
        return out
    }
    
    func getMessages(chatId: Int, limit: Int = 50) async throws -> [MaxMessage] {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }
        
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            guard let module = self.wrapperModule else {
                return "{\"success\": false, \"error\": \"Module not initialized\"}"
            }
            let result = module.get_messages(chatId, limit)
            return String(result) ?? "{}"
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool else {
            throw MaxClientError.invalidResponse
        }
        
        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.getMessagesFailed(error)
        }
        
        guard let messagesArray = json["messages"] as? [[String: Any]] else {
            print("⚠️ No messages array in response: \(json)")
            return []
        }
        
        let parsedMessages = messagesArray.compactMap { messageDict -> MaxMessage? in
            // id может быть String или Int, конвертируем в String
            var messageId: String?
            if let idString = messageDict["id"] as? String {
                messageId = idString
            } else if let idInt = messageDict["id"] as? Int {
                messageId = String(idInt)
            } else if let idNumber = messageDict["id"] as? NSNumber {
                messageId = idNumber.stringValue
            }
            
            guard let id = messageId else {
                print("⚠️ Invalid message dict: missing id - \(messageDict)")
                return nil
            }
            
            // chat_id может быть nil в JSON, в этом случае используем chatId из параметра функции
            var messageChatId: Int = chatId
            if let chatIdFromJson = messageDict["chat_id"] as? Int {
                messageChatId = chatIdFromJson
            } else if messageDict["chat_id"] is NSNull || messageDict["chat_id"] == nil {
                // chat_id равен null или отсутствует, используем переданный chatId
                messageChatId = chatId
            }
            
            let text = messageDict["text"] as? String ?? ""
            let senderId = messageDict["sender_id"] as? Int
            // Используем time, если есть, иначе date
            let date = (messageDict["time"] as? Int) ?? (messageDict["date"] as? Int)
            let type = messageDict["type"] as? String

            let replyTo = messageDict["reply_to"] as? String

            let reactions = messageDict["reactions"] as? [String: Int]

            var attachments: [MaxAttachment]? = nil
            if let rawAttaches = messageDict["attachments"] as? [[String: Any]] {
                let parsed = rawAttaches.compactMap { a -> MaxAttachment? in
                    let id = a["id"] as? Int ?? 0
                    let type = a["type"] as? String ?? "UNKNOWN"
                    let url = a["url"] as? String
                    let thumb = a["thumbnail_url"] as? String
                    let name = a["file_name"] as? String
                    let size = a["file_size"] as? Int
                    return MaxAttachment(id: id, type: type, url: url, thumbnailUrl: thumb, fileName: name, fileSize: size)
                }
                attachments = parsed.isEmpty ? nil : parsed
            }
            
            let message = MaxMessage(
                id: id,
                chatId: messageChatId,
                text: text,
                senderId: senderId,
                date: date,
                type: type,
                reactions: reactions,
                isPinned: false,
                replyTo: replyTo,
                attachments: attachments,
                isEdited: false
            )
            
            return message
        }
        messageIndex.upsert(chatId: chatId, messages: parsedMessages)
        return parsedMessages
    }

    func sendMessage(chatId: Int, text: String, replyTo: String? = nil) async throws -> MaxMessage {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let replyPy = replyTo != nil ? PythonObject(replyTo!) : PythonObject(Python.None)
            let result = module.send_message(chatId, text, replyPy)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.sendMessageFailed(error)
        }

        guard let msgDict = json["message"] as? [String: Any] else {
            throw MaxClientError.invalidResponse
        }

        guard let id = msgDict["id"] as? String else { throw MaxClientError.invalidResponse }
        guard let resolvedChatId = msgDict["chat_id"] as? Int else { throw MaxClientError.invalidResponse }
        let msgText = msgDict["text"] as? String ?? ""
        let senderId = msgDict["sender_id"] as? Int
        let date = (msgDict["time"] as? Int) ?? (msgDict["date"] as? Int)
        let type = msgDict["type"] as? String

        return MaxMessage(id: id, chatId: resolvedChatId, text: msgText, senderId: senderId, date: date, type: type)
    }

    func sendAttachment(
        chatId: Int,
        filePath: String,
        attachmentType: String,
        text: String = "",
        replyTo: String? = nil,
        notify: Bool = true
    ) async throws -> MaxMessage {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let replyPy = replyTo != nil ? PythonObject(replyTo!) : PythonObject(Python.None)
            let result = module.send_attachment(chatId, filePath, attachmentType, text, replyPy, notify)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.sendMessageFailed(error)
        }

        guard let msgDict = json["message"] as? [String: Any] else {
            throw MaxClientError.invalidResponse
        }

        guard let id = msgDict["id"] as? String else { throw MaxClientError.invalidResponse }
        guard let resolvedChatId = msgDict["chat_id"] as? Int else { throw MaxClientError.invalidResponse }
        let msgText = msgDict["text"] as? String ?? ""
        let senderId = msgDict["sender_id"] as? Int
        let date = (msgDict["time"] as? Int) ?? (msgDict["date"] as? Int)
        let type = msgDict["type"] as? String

        return MaxMessage(id: id, chatId: resolvedChatId, text: msgText, senderId: senderId, date: date, type: type)
    }

    func editMessage(chatId: Int, messageId: String, text: String) async throws -> MaxMessage {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.edit_message(chatId, messageId, text)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.editMessageFailed(error)
        }

        guard let msgDict = json["message"] as? [String: Any] else {
            throw MaxClientError.invalidResponse
        }

        guard let id = msgDict["id"] as? String else { throw MaxClientError.invalidResponse }
        guard let resolvedChatId = msgDict["chat_id"] as? Int else { throw MaxClientError.invalidResponse }
        let msgText = msgDict["text"] as? String ?? ""
        let senderId = msgDict["sender_id"] as? Int
        let date = (msgDict["time"] as? Int) ?? (msgDict["date"] as? Int)
        let type = msgDict["type"] as? String

        return MaxMessage(id: id, chatId: resolvedChatId, text: msgText, senderId: senderId, date: date, type: type, isEdited: true)
    }

    func deleteMessage(chatId: Int, messageIds: [String], forMe: Bool = true) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            // pass list as Python list
            let idsPy = PythonObject(messageIds)
            let result = module.delete_message(chatId, idsPy, forMe)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.deleteMessageFailed(error)
        }
    }

    func addReaction(chatId: Int, messageId: String, reaction: String) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.add_reaction(chatId, messageId, reaction)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.reactionFailed(error)
        }
    }

    func removeReaction(chatId: Int, messageId: String) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.remove_reaction(chatId, messageId)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.reactionFailed(error)
        }
    }

    func pinMessage(chatId: Int, messageId: String, notifyPin: Bool = true) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.pin_message(chatId, messageId, notifyPin)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.pinFailed(error)
        }
    }

    func uploadPhoto(filePath: String) async throws -> String {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.upload_photo(filePath)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.uploadFailed(error)
        }

        guard let token = json["photo_token"] as? String, !token.isEmpty else {
            throw MaxClientError.invalidResponse
        }
        return token
    }

    func uploadFile(filePath: String) async throws -> Int {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.upload_file(filePath)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.uploadFailed(error)
        }

        if let fileId = json["file_id"] as? Int {
            return fileId
        }
        if let fileIdStr = json["file_id"] as? String, let fileId = Int(fileIdStr) {
            return fileId
        }
        throw MaxClientError.invalidResponse
    }

    func updateProfile(firstName: String, lastName: String? = nil, about: String? = nil, photoPath: String? = nil) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let last = lastName != nil ? PythonObject(lastName!) : PythonObject(Python.None)
            let desc = about != nil ? PythonObject(about!) : PythonObject(Python.None)
            let photo = photoPath != nil ? PythonObject(photoPath!) : PythonObject(Python.None)
            let result = module.change_profile(firstName, last, desc, photo)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.profileUpdateFailed(error)
        }

        // Update visible user name if present
        if let me = json["me"] as? [String: Any],
           let id = me["id"] as? Int {
            let first = me["first_name"] as? String ?? firstName
            currentUser = MaxUser(id: id, firstName: first)
        }
    }

    func getFolders(folderSync: Int = 0) async throws -> [[String: Any]] {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.get_folders(folderSync)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.getFoldersFailed(error)
        }

        return (json["folders"] as? [[String: Any]]) ?? []
    }

    func searchUserByPhone(_ phone: String) async throws -> MaxUser {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.search_by_phone(phone)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.searchFailed(error)
        }

        guard let user = json["user"] as? [String: Any],
              let id = user["id"] as? Int else {
            throw MaxClientError.invalidResponse
        }

        let name = (user["name"] as? String) ?? "User"
        return MaxUser(id: id, firstName: name.isEmpty ? "User" : name)
    }

    func resolveChannelByName(_ name: String) async throws -> MaxChat {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.resolve_channel_by_name(name)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else {
            throw MaxClientError.invalidResponse
        }

        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.searchFailed(error)
        }

        guard let channel = json["channel"] as? [String: Any],
              let id = channel["id"] as? Int else {
            throw MaxClientError.invalidResponse
        }

        let title = (channel["title"] as? String) ?? "Channel"
        let iconUrl = channel["icon_url"] as? String
        return MaxChat(id: id, title: title, type: "CHANNEL", photoId: nil, iconUrl: iconUrl, unreadCount: 0)
    }

    func getPrivateChatWithUser(_ user: MaxUser) async throws -> MaxChat {
        guard let myId = currentUser?.id else {
            throw MaxClientError.missingToken
        }
        
        // Вычисляем ID приватного чата: first_user_id ^ second_user_id
        let chatId = myId ^ user.id
        
        // Проверяем, есть ли уже такой чат в кеше
        if let existingChat = chatsCache[chatId] {
            return existingChat
        }
        
        // Если чата нет в кеше, загружаем список чатов и ищем его там
        let allChats = try await getChats()
        if let foundChat = allChats.first(where: { $0.id == chatId }) {
            return foundChat
        }
        
        // Если чата нет, создаем новый объект чата (диалог будет создан автоматически при отправке первого сообщения)
        return MaxChat(
            id: chatId,
            title: user.firstName,
            type: "DIALOG",
            photoId: nil,
            iconUrl: nil,
            unreadCount: 0
        )
    }

    func createFolder(title: String, chatInclude: [Int]) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let includePy = PythonObject(chatInclude)
            let result = module.create_folder(title, includePy)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.foldersFailed(json["error"] as? String ?? "Unknown error")
        }
    }

    func updateFolder(folderId: String, title: String, chatInclude: [Int]?) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let includePy = chatInclude != nil ? PythonObject(chatInclude!) : PythonObject(Python.None)
            let result = module.update_folder(folderId, title, includePy)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.foldersFailed(json["error"] as? String ?? "Unknown error")
        }
    }

    func deleteFolder(folderId: String) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.delete_folder(folderId)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.foldersFailed(json["error"] as? String ?? "Unknown error")
        }
    }

    func joinGroup(link: String) async throws -> MaxChat {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.join_group(link)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.joinFailed(json["error"] as? String ?? "Unknown error")
        }

        guard let chat = json["chat"] as? [String: Any],
              let id = chat["id"] as? Int else { throw MaxClientError.invalidResponse }

        let title = chat["title"] as? String ?? "Chat"
        let type = chat["type"] as? String ?? "CHAT"
        let iconUrl = chat["icon_url"] as? String
        let resultChat = MaxChat(id: id, title: title, type: type, photoId: nil, iconUrl: iconUrl, unreadCount: 0)
        chatsCache[id] = resultChat
        return resultChat
    }

    func joinChannel(link: String) async throws -> MaxChat {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.join_channel(link)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.joinFailed(json["error"] as? String ?? "Unknown error")
        }

        guard let chat = json["chat"] as? [String: Any],
              let id = chat["id"] as? Int else { throw MaxClientError.invalidResponse }

        let title = chat["title"] as? String ?? "Channel"
        let type = chat["type"] as? String ?? "CHANNEL"
        let iconUrl = chat["icon_url"] as? String
        let resultChat = MaxChat(id: id, title: title, type: type, photoId: nil, iconUrl: iconUrl, unreadCount: 0)
        chatsCache[id] = resultChat
        return resultChat
    }

    func leaveGroup(chatId: Int) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.leave_group(chatId)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.leaveFailed(json["error"] as? String ?? "Unknown error")
        }
    }

    func leaveChannel(chatId: Int) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.leave_channel(chatId)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.leaveFailed(json["error"] as? String ?? "Unknown error")
        }
    }

    func markMessageRead(chatId: Int, messageId: String) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        let jsonString = try await PythonBridge.shared.withPythonAsync {
            let result = module.read_message(chatId, messageId)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            let success = json["success"] as? Bool
        else { throw MaxClientError.invalidResponse }

        if !success {
            throw MaxClientError.readFailed(json["error"] as? String ?? "Unknown error")
        }
    }
    
    func startClient() async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }
        
        // Получаем сохраненный токен и номер телефона
        let savedToken = UserDefaults.standard.string(forKey: "max_auth_token")
        let savedPhone = UserDefaults.standard.string(forKey: "max_phone_number")
        
        // Если есть токен, но wrapper еще не создан, создаем его с токеном
        if let token = savedToken, let phone = savedPhone {
            // Создаем wrapper с токеном для восстановления сессии
            try await createWrapper(phone: phone, token: token)
        }
        
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            guard let module = self.wrapperModule else {
                return "{\"success\": false, \"error\": \"Module not initialized\"}"
            }
            let result = module.start_client()
            return String(result) ?? "{}"
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let success = json["success"] as? Bool else {
            throw MaxClientError.invalidResponse
        }
        
        if !success {
            let error = json["error"] as? String ?? "Unknown error"
            throw MaxClientError.startClientFailed(error)
        }
        
        // Обновляем состояние авторизации
        if let authenticated = json["authenticated"] as? Bool {
            isAuthenticated = authenticated
        } else if json["requires_auth"] as? Bool == true {
            isAuthenticated = false
        } else if savedToken != nil {
            isAuthenticated = true
        }
        
        // Обновляем информацию о пользователе если есть
        if let me = json["me"] as? [String: Any],
           let id = me["id"] as? Int,
           let firstName = me["first_name"] as? String {
            currentUser = MaxUser(id: id, firstName: firstName)
            myUserId = id
            UserDefaults.standard.set(id, forKey: "max_user_id")
        }

        // Best-effort: enable events right after client start so UI gets real-time updates.
        try? await startEventMonitoring()
    }

    func startEventMonitoring(eventsDir: String? = nil) async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }

        // Ask Python wrapper to register callbacks + tell us events dir
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            // Anchor events dir to Documents/max_cache/events by default, so Swift and Python always agree.
            let dir: String? = {
                if let eventsDir { return eventsDir }
                let fm = FileManager.default
                let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
                return docs?.appendingPathComponent("max_cache/events", isDirectory: true).path
            }()
            let dirPy = dir != nil ? PythonObject(dir!) : PythonObject(Python.None)
            let result = module.register_event_callbacks(dirPy)
            return String(result) ?? "{}"
        }

        guard
            let jsonData = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
            (json["success"] as? Bool) == true,
            let eventsDirResolved = json["events_dir"] as? String
        else {
            throw MaxClientError.invalidResponse
        }

        // Restart monitor if needed
        eventMonitor?.stop()
        let monitor = EventMonitor(directoryPath: eventsDirResolved)
        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            Task { @MainActor in
                self.handlePythonEvent(event)
            }
        }
        eventMonitor = monitor
        monitor.start()
    }

    func stopEventMonitoring() {
        eventMonitor?.stop()
        eventMonitor = nil
    }

    private func handlePythonEvent(_ event: [String: Any]) {
        guard let type = event["type"] as? String else { return }

        switch type {
        case "message_new":
            if let msg = parseMessageEvent(event) {
                newMessages.append(msg)
                messageIndex.upsert(chatId: msg.chatId, messages: [msg])
            }
        case "message_edit":
            if let msg = parseMessageEvent(event) {
                updatedMessages.append(msg)
                messageIndex.upsert(chatId: msg.chatId, messages: [msg])
            }
        case "message_delete":
            if let message = event["message"] as? [String: Any],
               let chatId = message["chat_id"] as? Int,
               let messageId = message["id"] as? String {
                deletedMessageIds.append((chatId: chatId, messageId: messageId))
                messageIndex.delete(chatId: chatId, messageIds: [messageId])
            }
        case "reaction_change":
            if let chatId = event["chat_id"] as? Int,
               let messageId = event["message_id"] as? String {
                let info = event["reaction_info"] as? [String: Any]
                let reaction = info?["your_reaction"] as? String
                reactionUpdates.append((chatId: chatId, messageId: messageId, reaction: reaction))
            }
        case "chat_update":
            if let raw = event["chat"] as? [String: Any],
               let id = raw["id"] as? Int {
                let title = (raw["title"] as? String) ?? ""
                let type = (raw["type"] as? String) ?? "unknown"
                let iconUrl = raw["icon_url"] as? String
                let updated = MaxChat(id: id, title: title, type: type, photoId: nil, iconUrl: iconUrl, unreadCount: 0)
                // Keep cache in sync for other screens (best-effort)
                chatsCache[id] = updated
                chatUpdates.append(updated)
            }
        default:
            break
        }
    }

    private func parseMessageEvent(_ event: [String: Any]) -> MaxMessage? {
        guard let message = event["message"] as? [String: Any] else { return nil }

        guard let id = message["id"] as? String else { return nil }
        guard let chatId = message["chat_id"] as? Int else { return nil }

        let text = message["text"] as? String ?? ""
        let senderId = message["sender_id"] as? Int
        let date = (message["time"] as? Int) ?? (message["date"] as? Int)
        let type = message["type"] as? String

        let replyTo = message["reply_to"] as? String
        let reactions = message["reactions"] as? [String: Int]

        var attachments: [MaxAttachment]? = nil
        if let rawAttaches = message["attachments"] as? [[String: Any]] {
            let parsed = rawAttaches.compactMap { a -> MaxAttachment? in
                let id = a["id"] as? Int ?? 0
                let type = a["type"] as? String ?? "UNKNOWN"
                let url = a["url"] as? String
                let thumb = a["thumbnail_url"] as? String
                let name = a["file_name"] as? String
                let size = a["file_size"] as? Int
                return MaxAttachment(id: id, type: type, url: url, thumbnailUrl: thumb, fileName: name, fileSize: size)
            }
            attachments = parsed.isEmpty ? nil : parsed
        }

        return MaxMessage(
            id: id,
            chatId: chatId,
            text: text,
            senderId: senderId,
            date: date,
            type: type,
            reactions: reactions,
            isPinned: false,
            replyTo: replyTo,
            attachments: attachments,
            isEdited: (event["type"] as? String) == "message_edit"
        )
    }
    
    func stopClient() async throws {
        guard let module = wrapperModule else {
            throw MaxClientError.notInitialized
        }
        
        let jsonString = try await PythonBridge.shared.withPythonAsync {
            guard let module = self.wrapperModule else {
                return "{\"success\": false, \"error\": \"Module not initialized\"}"
            }
            let result = module.stop_client()
            return String(result) ?? "{}"
        }
        guard let jsonData = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw MaxClientError.invalidResponse
        }
        
        // Очищаем состояние и токен
        isAuthenticated = false
        currentUser = nil
        stopEventMonitoring()
        UserDefaults.standard.removeObject(forKey: "max_auth_token")
        UserDefaults.standard.removeObject(forKey: "max_phone_number")
    }
    
    func logout() async throws {
        // Выход из системы - очищаем токен и останавливаем клиент
        try await stopClient()
    }
    
    func checkAuthentication() -> Bool {
        return UserDefaults.standard.string(forKey: "max_auth_token") != nil
    }
}

enum MaxClientError: LocalizedError {
    case notInitialized
    case invalidResponse
    case pymaxNotAvailable
    case wrapperCreationFailed(String)
    case requestCodeFailed(String)
    case loginFailed(String)
    case getChatsFailed(String)
    case getMessagesFailed(String)
    case startClientFailed(String)
    case sendMessageFailed(String)
    case editMessageFailed(String)
    case deleteMessageFailed(String)
    case reactionFailed(String)
    case pinFailed(String)
    case uploadFailed(String)
    case profileUpdateFailed(String)
    case getFoldersFailed(String)
    case searchFailed(String)
    case foldersFailed(String)
    case joinFailed(String)
    case leaveFailed(String)
    case readFailed(String)
    case missingToken
    case invalidUserData
    
    var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Python bridge not initialized"
        case .invalidResponse:
            return "Invalid response from Python"
        case .pymaxNotAvailable:
            return "pymax not available - missing dependencies (pydantic-core required)"
        case .wrapperCreationFailed(let message):
            // Do not hide diagnostics. We rely on wrapper-provided details (e.g. OSError/dlopen).
            return "Failed to create wrapper: \(message)"
        case .requestCodeFailed(let message):
            return "Failed to request code: \(message)"
        case .loginFailed(let message):
            return "Login failed: \(message)"
        case .getChatsFailed(let message):
            return "Failed to get chats: \(message)"
        case .getMessagesFailed(let message):
            return "Failed to get messages: \(message)"
        case .startClientFailed(let message):
            return "Failed to start client: \(message)"
        case .sendMessageFailed(let message):
            return "Failed to send message: \(message)"
        case .editMessageFailed(let message):
            return "Failed to edit message: \(message)"
        case .deleteMessageFailed(let message):
            return "Failed to delete message: \(message)"
        case .reactionFailed(let message):
            return "Failed to update reaction: \(message)"
        case .pinFailed(let message):
            return "Failed to pin message: \(message)"
        case .uploadFailed(let message):
            return "Failed to upload attachment: \(message)"
        case .profileUpdateFailed(let message):
            return "Failed to update profile: \(message)"
        case .getFoldersFailed(let message):
            return "Failed to get folders: \(message)"
        case .searchFailed(let message):
            return "Search failed: \(message)"
        case .foldersFailed(let message):
            return "Folders operation failed: \(message)"
        case .joinFailed(let message):
            return "Join failed: \(message)"
        case .leaveFailed(let message):
            return "Leave failed: \(message)"
        case .readFailed(let message):
            return "Read marker failed: \(message)"
        case .missingToken:
            return "Missing authentication token"
        case .invalidUserData:
            return "Invalid user data"
        }
    }
}
