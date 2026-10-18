import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// The message, on the sheet: its subject as a title, the line of sender and date in small
/// monospaced letters (as the dates of a note), the recipients, the attachments, then the text.
/// An HTML message is shown without JavaScript and without what it would load from the Internet,
/// until « Charger les images ».
struct MessageView: View {
    let summary: MessageSummary
    @Environment(MailModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(summary.subject.isEmpty ? "(sans objet)" : summary.subject)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Theme.primaryText)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                    MessageActions(summary: summary)
                }
                Text("De \(sender) · \(MailDate.sentence(summary.date))")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
                    .help(summary.sender.address)
                if !summary.recipients.isEmpty {
                    Text("À \(summary.recipients)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(2)
                }
                if let message = model.openMessage, !message.attachments.isEmpty {
                    AttachmentStrip(attachments: message.attachments)
                        .padding(.top, 6)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 26)
            .padding(.bottom, 14)

            Rectangle().fill(Theme.stroke).frame(height: 1).padding(.horizontal, 32)

            Group {
                if let message = model.openMessage {
                    content(message)
                } else if model.loadingMessage {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sender: String {
        summary.sender.name.isEmpty ? summary.sender.address : "\(summary.sender.name) <\(summary.sender.address)>"
    }

    @ViewBuilder private func content(_ message: MailMessage) -> some View {
        if let html = message.html {
            VStack(spacing: 0) {
                if message.hasRemoteImages, !model.showsRemoteImages {
                    HStack(spacing: 8) {
                        Image(systemName: "eye.slash").font(.system(size: 11))
                        Text("Images distantes bloquées : elles diraient à l'expéditeur que le message est lu.")
                            .font(.system(size: 11))
                        Spacer()
                        Button("Charger les images") { model.showsRemoteImages = true }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 8)
                }
                // Mail is written for white paper: the HTML keeps its own page, on a card.
                HTMLMessageView(html: html, allowsRemote: model.showsRemoteImages)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.stroke))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
            }
        } else {
            ScrollView {
                Text(Self.linked(message.plainText ?? ""))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .foregroundStyle(Theme.primaryText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 20)
            }
        }
    }

    /// Plain text with its addresses made links (underlined in the accent, as in Void Notes).
    static func linked(_ text: String) -> AttributedString {
        var result = AttributedString(text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let source = text as NSString
        for match in detector.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let url = match.url, let range = Range(match.range, in: text),
                  let lower = AttributedString.Index(range.lowerBound, within: result),
                  let upper = AttributedString.Index(range.upperBound, within: result) else { continue }
            result[lower..<upper].link = url
            result[lower..<upper].underlineStyle = .single
        }
        return result
    }
}

/// At the end of the subject line, as the buttons by a note's title: pin, unread, archive, trash.
private struct MessageActions: View {
    let summary: MessageSummary
    @Environment(MailModel.self) private var model
    @Environment(AccountStore.self) private var store

    var body: some View {
        let account = store.account(summary.account)
        let inArchive = account.flatMap(model.archivePath(of:)) == summary.mailbox
        let inTrash = account.flatMap(model.trashPath(of:)).map { $0 == summary.mailbox } ?? true
        HStack(spacing: 2) {
            ChromeButton(symbol: summary.isFlagged ? "pin.fill" : "pin", help: summary.isFlagged ? "Désépingler (⌃⌘P)" : "Épingler en tête (⌃⌘P)",
                         active: summary.isFlagged) { model.togglePinned() }
            ChromeButton(symbol: summary.isSeen ? "envelope.badge" : "envelope.open", help: summary.isSeen ? "Marquer comme non lu (U)" : "Marquer comme lu (U)") { model.toggleSeen() }
            ChromeButton(symbol: inArchive ? "tray.and.arrow.down" : "archivebox", help: inArchive ? "Remettre en Réception (E)" : "Archiver (E)") { model.archiveSelected() }
            ChromeButton(symbol: inTrash ? "trash.slash" : "trash", help: inTrash ? "Supprimer définitivement… (⌫)" : "Mettre à la corbeille (⌫)") { model.trashSelected() }
        }
    }
}

/// Attachments as small cards: icon, name, size. A click opens a copy in its app.
private struct AttachmentStrip: View {
    let attachments: [MailMessage.Attachment]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    Button { open(attachment) } label: {
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: attachment.contentType) ?? .data))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(attachment.filename).font(.system(size: 11)).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                    }
                    .buttonStyle(.plain)
                    .help("Ouvrir « \(attachment.filename) »")
                }
            }
        }
    }

    /// A copy in the app's temporary folder, opened by its app.
    private func open(_ attachment: MailMessage.Attachment) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = attachment.filename.replacingOccurrences(of: "/", with: "-")
        let url = folder.appendingPathComponent(name.isEmpty ? "pièce jointe" : name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try attachment.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            NSSound.beep()
        }
    }
}

/// An HTML message: no JavaScript, nothing from the Internet unless allowed (a Content Security
/// Policy in front of the page), no cookies; links open in the browser.
struct HTMLMessageView: NSViewRepresentable {
    let html: String
    let allowsRemote: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(html.hashValue)\(allowsRemote)"
        guard context.coordinator.loaded != key else { return }
        context.coordinator.loaded = key
        view.loadHTMLString(Self.page(html, allowsRemote: allowsRemote), baseURL: nil)
    }

    static func page(_ html: String, allowsRemote: Bool) -> String {
        let sources = allowsRemote ? "data: cid: https: http:" : "data: cid:"
        let policy = "<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src \(sources); style-src 'unsafe-inline' \(allowsRemote ? "https:" : ""); font-src \(sources)\">"
        let base = "<style>html{background:#fff;color:#131316}body{margin:0;padding:20px 24px;font:14px -apple-system,sans-serif;word-wrap:break-word}img{max-width:100%;height:auto}</style>"
        // In front of everything, so that the message's own <head> can't come before the policy.
        return policy + base + html
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: String?

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { NSWorkspace.shared.open(url) }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(action.request.url?.scheme == "about" || action.request.url == nil ? .allow : .cancel)
        }
    }
}
