//
//  MessagesView.swift
//  whitemax
//
//  Экран с сообщениями чата
//

import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Photos

struct MessagesView: View {
    let chat: MaxChat
    var initialScrollToMessageId: String? = nil
    
    @StateObject private var service = MaxClientService.shared
    @State private var messages: [MaxMessage] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var draftText: String = ""
    @State private var isSending: Bool = false
    @State private var replyingTo: MaxMessage?
    @State private var editingMessage: MaxMessage?

    @State private var reactionTarget: MaxMessage?

    @State private var showAttachmentSheet: Bool = false
    @State private var showFileImporter: Bool = false
    @State private var showPhotoPicker: Bool = false
    @State private var pickedPhotoItem: PhotosPickerItem?

    @State private var pendingAttachment: PendingAttachment?
    @State private var sendErrorMessage: String?
    @State private var previewAttachment: MaxAttachment?
    @State private var shareFileURL: URL?
    @State private var showShareSheet = false
    @State private var showSaveSuccessAlert = false
    @State private var saveError: String?

    struct PendingAttachment: Identifiable {
        enum Kind { case photo, file }
        let id = UUID()
        let kind: Kind
        let localURL: URL
        let displayName: String
        let previewImage: UIImage?
    }
    
    var body: some View {
        ZStack {
            background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                content

                Divider().opacity(0.2)

                VStack(spacing: 8) {
                    if let editingMessage {
                        ComposerBanner(
                            title: "Редактирование",
                            subtitle: editingMessage.text
                        ) {
                            self.editingMessage = nil
                            self.draftText = ""
                        }
                    } else if let replyingTo {
                        ComposerBanner(
                            title: "Ответ",
                            subtitle: replyingTo.text
                        ) {
                            self.replyingTo = nil
                        }
                    }

                    composer
                }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            if reactionTarget != nil {
                ReactionPickerView { reaction in
                    react(reaction)
                }
                .padding(.bottom, 90)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Вложение", isPresented: $showAttachmentSheet, titleVisibility: .visible) {
            Button("Фото из галереи") {
                showPhotoPicker = true
            }
            Button("Файл") {
                showFileImporter = true
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $pickedPhotoItem,
            matching: .images
        )
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task { await stagePickedFile(url: url) }
            case .failure:
                break
            }
        }
        .task {
            await loadMessagesAsync()
            // Enable real-time events (best-effort)
            try? await service.startEventMonitoring()
        }
        .onChange(of: service.newMessages.count) { _ in
            guard let last = service.newMessages.last else { return }
            guard last.chatId == chat.id else { return }
            if !messages.contains(where: { $0.id == last.id }) {
                messages.append(last)
            }
        }
        .onChange(of: service.updatedMessages.count) { _ in
            guard let last = service.updatedMessages.last else { return }
            guard last.chatId == chat.id else { return }
            if let idx = messages.firstIndex(where: { $0.id == last.id }) {
                messages[idx] = last
            }
        }
        .onChange(of: service.deletedMessageIds.count) { _ in
            guard let last = service.deletedMessageIds.last else { return }
            guard last.chatId == chat.id else { return }
            messages.removeAll { $0.id == last.messageId }
        }
        .onChange(of: pickedPhotoItem) { _, newItem in
            guard let newItem else { return }
            Task { await stagePickedPhoto(item: newItem) }
        }
        .sheet(item: $previewAttachment) { a in
            AttachmentPreviewSheet(attachment: a)
        }
        .sheet(isPresented: $showShareSheet) {
            if let fileURL = shareFileURL {
                ShareSheet(items: [fileURL])
            }
        }
        .alert("Сохранено", isPresented: $showSaveSuccessAlert) {
            Button("OK") { }
        } message: {
            Text("Вложение успешно сохранено")
        }
        .alert("Ошибка", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            if let error = saveError {
                Text(error)
            }
        }
    }

    private var content: some View {
        Group {
            if isLoading {
                ProgressView("Загрузка сообщений…")
                    .padding()
                    .liquidGlass(cornerRadius: 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView(
                    "Не удалось загрузить сообщения",
                    systemImage: "wifi.exclamationmark",
                    description: Text(error)
                )
                .overlay(alignment: .bottom) {
                    Button("Повторить") { loadMessages() }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView(
                    "Нет сообщений",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Напишите первое сообщение в этом чате.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    isOutgoing: isOutgoing(message),
                                        onReply: { startReply(to: message) },
                                        onEdit: { startEdit(message) },
                                        onReact: { reactionTarget = message },
                                    onDelete: { deleteMessage(message) },
                                    onPin: { pinMessage(message) },
                                    onOpenAttachment: { a in
                                        previewAttachment = a
                                    },
                                    onSaveAttachment: { attachment in
                                        Task { await saveAttachmentDirectly(attachment) }
                                    },
                                    onShareAttachment: { attachment in
                                        Task { await shareAttachmentDirectly(attachment) }
                                    }
                                )
                                .id(message.id)
                            }

                            Color.clear
                                .frame(height: 1)
                                .id("bottom")
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .refreshable {
                        await loadMessagesAsync()
                    }
                    .onChange(of: messages.count) { _ in
                        if let target = initialScrollToMessageId, messages.contains(where: { $0.id == target }) {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(target, anchor: .center)
                            }
                        } else {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let target = initialScrollToMessageId, messages.contains(where: { $0.id == target }) {
                            proxy.scrollTo(target, anchor: .center)
                        } else {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            if let pendingAttachment {
                AttachmentChip(attachment: pendingAttachment) {
                    self.pendingAttachment = nil
                }
                .transition(.opacity)
            }

            if let sendErrorMessage {
                ComposerErrorBanner(message: sendErrorMessage) {
                    self.sendErrorMessage = nil
                } onRetry: {
                    self.sendErrorMessage = nil
                    send()
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            MessageInputView(
                text: $draftText,
                isSending: isSending,
                onAttach: { showAttachmentSheet = true },
                onSend: send
            )
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.18),
                Color(uiColor: .systemBackground),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay { Rectangle().fill(.ultraThinMaterial).opacity(0.6) }
    }
    
    private func loadMessages() {
        Task {
            await loadMessagesAsync()
        }
    }
    
    private func loadMessagesAsync() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let loadedMessages = try await service.getMessages(chatId: chat.id, limit: 50)
            await MainActor.run {
                // Сообщения уже отсортированы по времени (старые первыми, новые последними)
                self.messages = loadedMessages
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    private func isOutgoing(_ message: MaxMessage) -> Bool {
        guard let myId = service.currentUser?.id else { return false }
        return message.senderId == myId
    }

    private func send() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        if pendingAttachment == nil {
            guard !text.isEmpty else { return }
        }

        isSending = true
        sendErrorMessage = nil

        Task {
            defer { Task { @MainActor in isSending = false } }
            do {
                if let editingMessage {
                    let edited = try await service.editMessage(chatId: chat.id, messageId: editingMessage.id, text: text)
                    await MainActor.run {
                        if let idx = messages.firstIndex(where: { $0.id == edited.id }) {
                            messages[idx] = edited
                        }
                        self.editingMessage = nil
                        self.draftText = ""
                    }
                } else {
                    let replyToId = replyingTo?.id
                    let sent: MaxMessage
                    if let pendingAttachment {
                        let kind = (pendingAttachment.kind == .photo) ? "photo" : "file"
                        sent = try await service.sendAttachment(
                            chatId: chat.id,
                            filePath: pendingAttachment.localURL.path,
                            attachmentType: kind,
                            text: text,
                            replyTo: replyToId,
                            notify: true
                        )
                    } else {
                        sent = try await service.sendMessage(chatId: chat.id, text: text, replyTo: replyToId)
                    }
                    await MainActor.run {
                        if !messages.contains(where: { $0.id == sent.id }) {
                            messages.append(sent)
                        }
                        self.replyingTo = nil
                        self.pendingAttachment = nil
                        self.draftText = ""
                    }
                }
            } catch {
                await MainActor.run {
                    sendErrorMessage = error.localizedDescription
                }
            }
        }
    }

    private func stagePickedPhoto(item: PhotosPickerItem) async {
        // PhotosPicker: no blanket library access; we only receive the selected asset.
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let url = try writeTempFile(data: data, preferredExtension: "jpg")
            let preview = UIImage(data: data)
            await MainActor.run {
                pendingAttachment = PendingAttachment(kind: .photo, localURL: url, displayName: "Фото", previewImage: preview)
                pickedPhotoItem = nil
            }
        } catch {
            await MainActor.run {
                sendErrorMessage = error.localizedDescription
                pickedPhotoItem = nil
            }
        }
    }

    private func stagePickedFile(url: URL) async {
        // UIDocumentPicker-style selection: no extra permissions; user explicitly picks a file.
        let scoped = url.startAccessingSecurityScopedResource()
        defer {
            if scoped { url.stopAccessingSecurityScopedResource() }
        }

        do {
            let ext = url.pathExtension.isEmpty ? "bin" : url.pathExtension
            let tmp = try stageTempCopy(from: url, preferredExtension: ext)
            await MainActor.run {
                pendingAttachment = PendingAttachment(kind: .file, localURL: tmp, displayName: url.lastPathComponent, previewImage: nil)
            }
        } catch {
            await MainActor.run {
                sendErrorMessage = error.localizedDescription
            }
        }
    }

    private func writeTempFile(data: Data, preferredExtension ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whitemax_uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = UUID().uuidString + "." + ext
        let url = dir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    private func stageTempCopy(from url: URL, preferredExtension ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("whitemax_uploads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let filename = UUID().uuidString + "." + ext
        let dst = dir.appendingPathComponent(filename)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.copyItem(at: url, to: dst)
        return dst
    }

    private func startReply(to message: MaxMessage) {
        replyingTo = message
        editingMessage = nil
    }

    private func startEdit(_ message: MaxMessage) {
        editingMessage = message
        replyingTo = nil
        draftText = message.text
    }

    private func react(_ reaction: String) {
        guard let target = reactionTarget else { return }
        reactionTarget = nil

        Task {
            do {
                try await service.addReaction(chatId: chat.id, messageId: target.id, reaction: reaction)
            } catch {
                // ignore for now (UI polish later)
            }
        }
    }

    private func deleteMessage(_ message: MaxMessage) {
        Task {
            do {
                try await service.deleteMessage(chatId: chat.id, messageIds: [message.id], forMe: true)
                await MainActor.run {
                    messages.removeAll { $0.id == message.id }
                }
            } catch {
                // ignore for now (UI polish later)
            }
        }
    }

    private func pinMessage(_ message: MaxMessage) {
        Task {
            do {
                try await service.pinMessage(chatId: chat.id, messageId: message.id, notifyPin: true)
            } catch {
                // ignore for now (UI polish later)
            }
        }
    }
    
    private func saveAttachmentDirectly(_ attachment: MaxAttachment) async {
        guard let urlString = attachment.url,
              let url = URL(string: urlString) else {
            await MainActor.run {
                saveError = "URL вложения недоступен"
            }
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            if attachment.type.uppercased() == "PHOTO" {
                // Сохраняем фото в Photos library
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    await MainActor.run {
                        saveError = "Необходим доступ к библиотеке фото"
                    }
                    return
                }
                
                guard let image = UIImage(data: data) else {
                    await MainActor.run {
                        saveError = "Не удалось создать изображение"
                    }
                    return
                }
                
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                
                await MainActor.run {
                    showSaveSuccessAlert = true
                }
            } else {
                // Сохраняем файл в Documents
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileName = attachment.fileName ?? "attachment_\(attachment.id)"
                let fileURL = documentsPath.appendingPathComponent(fileName)
                
                try data.write(to: fileURL)
                
                await MainActor.run {
                    showSaveSuccessAlert = true
                }
            }
        } catch {
            await MainActor.run {
                saveError = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }
    
    private func shareAttachmentDirectly(_ attachment: MaxAttachment) async {
        guard let urlString = attachment.url,
              let url = URL(string: urlString) else {
            await MainActor.run {
                saveError = "URL вложения недоступен"
            }
            return
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Сохраняем во временный файл для sharing
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = attachment.fileName ?? "attachment_\(attachment.id)"
            let tempFileURL = tempDir.appendingPathComponent(fileName)
            
            try data.write(to: tempFileURL)
            
            await MainActor.run {
                shareFileURL = tempFileURL
                showShareSheet = true
            }
        } catch {
            await MainActor.run {
                saveError = "Не удалось загрузить: \(error.localizedDescription)"
            }
        }
    }
}

private struct AttachmentPreviewSheet: View {
    let attachment: MaxAttachment
    
    @State private var isDownloading = false
    @State private var downloadError: String?
    @State private var downloadedFileURL: URL?
    @State private var showShareSheet = false
    @State private var showSaveSuccess = false

    var body: some View {
        NavigationStack {
            Group {
                if attachment.type.uppercased() == "PHOTO",
                   let s = attachment.url,
                   let url = URL(string: s) {
                    ScrollView {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: .infinity)
                            case .failure:
                                ContentUnavailableView("Не удалось загрузить фото", systemImage: "photo.badge.exclamationmark")
                                    .padding(.top, 32)
                            default:
                                ProgressView("Загрузка…")
                                    .padding(.top, 32)
                            }
                        }
                        .padding()
                    }
                    .background(Color(uiColor: .systemBackground))
                } else {
                    ContentUnavailableView(
                        "Вложение",
                        systemImage: "paperclip",
                        description: Text(attachment.fileName ?? attachment.type)
                    )
                    .padding()
                }
            }
            .navigationTitle(attachment.fileName ?? "Вложение")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button {
                            Task { await saveAttachment() }
                        } label: {
                            Label("Сохранить", systemImage: "square.and.arrow.down")
                        }
                        .disabled(isDownloading || attachment.url == nil)
                        
                        Button {
                            Task { await shareAttachment() }
                        } label: {
                            Label("Отправить", systemImage: "square.and.arrow.up")
                        }
                        .disabled(isDownloading || attachment.url == nil)
                    } label: {
                        if isDownloading {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .alert("Ошибка", isPresented: .constant(downloadError != nil)) {
                Button("OK") { downloadError = nil }
            } message: {
                if let error = downloadError {
                    Text(error)
                }
            }
            .alert("Сохранено", isPresented: $showSaveSuccess) {
                Button("OK") { }
            } message: {
                Text("Вложение успешно сохранено")
            }
            .sheet(isPresented: $showShareSheet) {
                if let fileURL = downloadedFileURL {
                    ShareSheet(items: [fileURL])
                }
            }
        }
    }
    
    private func saveAttachment() async {
        guard let urlString = attachment.url,
              let url = URL(string: urlString) else {
            await MainActor.run {
                downloadError = "URL вложения недоступен"
            }
            return
        }
        
        await MainActor.run {
            isDownloading = true
            downloadError = nil
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            if attachment.type.uppercased() == "PHOTO" {
                // Сохраняем фото в Photos library
                let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                guard status == .authorized || status == .limited else {
                    await MainActor.run {
                        isDownloading = false
                        downloadError = "Необходим доступ к библиотеке фото"
                    }
                    return
                }
                
                guard let image = UIImage(data: data) else {
                    await MainActor.run {
                        isDownloading = false
                        downloadError = "Не удалось создать изображение"
                    }
                    return
                }
                
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: image)
                }
                
                await MainActor.run {
                    isDownloading = false
                    showSaveSuccess = true
                }
            } else {
                // Сохраняем файл в Documents
                let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                let fileName = attachment.fileName ?? "attachment_\(attachment.id)"
                let fileURL = documentsPath.appendingPathComponent(fileName)
                
                try data.write(to: fileURL)
                
                await MainActor.run {
                    isDownloading = false
                    showSaveSuccess = true
                }
            }
        } catch {
            await MainActor.run {
                isDownloading = false
                downloadError = "Не удалось сохранить: \(error.localizedDescription)"
            }
        }
    }
    
    private func shareAttachment() async {
        guard let urlString = attachment.url,
              let url = URL(string: urlString) else {
            await MainActor.run {
                downloadError = "URL вложения недоступен"
            }
            return
        }
        
        await MainActor.run {
            isDownloading = true
            downloadError = nil
        }
        
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            
            // Сохраняем во временный файл для sharing
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = attachment.fileName ?? "attachment_\(attachment.id)"
            let tempFileURL = tempDir.appendingPathComponent(fileName)
            
            try data.write(to: tempFileURL)
            
            await MainActor.run {
                downloadedFileURL = tempFileURL
                isDownloading = false
                showShareSheet = true
            }
        } catch {
            await MainActor.run {
                isDownloading = false
                downloadError = "Не удалось загрузить: \(error.localizedDescription)"
            }
        }
    }
}

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}

private struct ComposerBanner: View {
    let title: String
    let subtitle: String
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(subtitle)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16, material: .thinMaterial)
    }
}

private struct AttachmentChip: View {
    let attachment: MessagesView.PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if let img = attachment.previewImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Image(systemName: attachment.kind == .photo ? "photo" : "doc")
                    .imageScale(.large)
                    .frame(width: 38, height: 38)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            Text(attachment.displayName)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16, material: .thinMaterial)
    }
}

private struct ComposerErrorBanner: View {
    let message: String
    let onClose: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.orange)

            Text(message)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button("Retry", action: onRetry)
                .font(.caption.weight(.semibold))

            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16, material: .thinMaterial)
    }
}

#Preview {
    NavigationStack {
        MessagesView(chat: MaxChat(
            id: 1,
            title: "Test Chat",
            type: "PRIVATE",
            photoId: nil,
            iconUrl: nil,
            unreadCount: 0
        ))
    }
}
