//
//  MessageBubbleView.swift
//  whitemax
//

import SwiftUI

struct MessageBubbleView: View {
    let message: MaxMessage
    let isOutgoing: Bool
    let onReply: () -> Void
    let onEdit: () -> Void
    let onReact: () -> Void
    let onDelete: () -> Void
    let onPin: () -> Void
    let onOpenAttachment: (MaxAttachment) -> Void
    var onSaveAttachment: ((MaxAttachment) -> Void)? = nil
    var onShareAttachment: ((MaxAttachment) -> Void)? = nil

    var body: some View {
        HStack {
            if isOutgoing { Spacer(minLength: 32) }

            VStack(alignment: isOutgoing ? .trailing : .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 8) {
                    if let replyTo = message.replyTo, !replyTo.isEmpty {
                        HStack(spacing: 6) {
                            Rectangle()
                                .fill(.white.opacity(isOutgoing ? 0.22 : 0.15))
                                .frame(width: 2)
                            Text("Ответ на #\(replyTo)")
                                .font(.caption)
                                .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .secondary)
                        }
                    }

                    if let attachments = message.attachments, !attachments.isEmpty {
                        AttachmentListView(attachments: attachments, isOutgoing: isOutgoing, onOpen: onOpenAttachment)
                    }

                    if !message.text.isEmpty {
                        Text(message.text)
                            .font(.body)
                            .foregroundStyle(isOutgoing ? .white : .primary)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(.white.opacity(isOutgoing ? 0.08 : 0.12), lineWidth: 1)
                }

                HStack(spacing: 6) {
                    if message.isEdited {
                        Text("изменено")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    if let date = message.date {
                        Text(Self.formatTime(date))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contextMenu {
                Button {
                    onReply()
                } label: {
                    Label("Ответить", systemImage: "arrowshape.turn.up.left")
                }

                Button {
                    onReact()
                } label: {
                    Label("Реакция", systemImage: "face.smiling")
                }

                if isOutgoing {
                    Button {
                        onEdit()
                    } label: {
                        Label("Редактировать", systemImage: "pencil")
                    }
                }

                Button {
                    UIPasteboard.general.string = message.text
                } label: {
                    Label("Скопировать", systemImage: "doc.on.doc")
                }
                
                if let attachments = message.attachments, !attachments.isEmpty {
                    Divider()
                    
                    ForEach(attachments) { attachment in
                        if let onSave = onSaveAttachment {
                            Button {
                                onSave(attachment)
                            } label: {
                                Label("Сохранить \(attachment.fileName ?? "вложение")", systemImage: "square.and.arrow.down")
                            }
                        }
                        
                        if let onShare = onShareAttachment {
                            Button {
                                onShare(attachment)
                            } label: {
                                Label("Отправить \(attachment.fileName ?? "вложение")", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                }

                Button {
                    onPin()
                } label: {
                    Label("Закрепить", systemImage: "pin")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Удалить", systemImage: "trash")
                }
            }

            if !isOutgoing { Spacer(minLength: 32) }
        }
    }

    private struct AttachmentListView: View {
        let attachments: [MaxAttachment]
        let isOutgoing: Bool
        let onOpen: (MaxAttachment) -> Void

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(attachments) { a in
                    Button {
                        onOpen(a)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: icon(for: a))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(isOutgoing ? .white.opacity(0.9) : .secondary)

                            Text(title(for: a))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(isOutgoing ? .white : .primary)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            if let fileSize = a.fileSize, fileSize > 0 {
                                Text(Self.formatBytes(fileSize))
                                    .font(.caption2)
                                    .foregroundStyle(isOutgoing ? .white.opacity(0.85) : .secondary)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(.thinMaterial.opacity(isOutgoing ? 0.25 : 0.8), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(.white.opacity(isOutgoing ? 0.10 : 0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }

        private func icon(for a: MaxAttachment) -> String {
            switch a.type.uppercased() {
            case "PHOTO": return "photo"
            case "VIDEO": return "video"
            case "FILE": return "doc"
            default: return "paperclip"
            }
        }

        private func title(for a: MaxAttachment) -> String {
            if let name = a.fileName, !name.isEmpty { return name }
            switch a.type.uppercased() {
            case "PHOTO": return "Фото"
            case "VIDEO": return "Видео"
            case "FILE": return "Файл"
            default: return "Вложение"
            }
        }

        private static func formatBytes(_ bytes: Int) -> String {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter.string(fromByteCount: Int64(bytes))
        }
    }

    private var bubbleBackground: some ShapeStyle {
        if isOutgoing {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(.thinMaterial)
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

