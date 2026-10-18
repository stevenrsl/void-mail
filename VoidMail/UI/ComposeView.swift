import SwiftUI
import UniformTypeIdentifiers

/// A message being written, in a window of its own, on Void's chrome: the addresses and the
/// subject, then the text on the sheet — Void Notes' editor, marks typed and gone (`# `, `- `,
/// `**gras**`, `> `…). « Envoyer » (⌘↩) closes the window; the message leaves 10 s later.
/// Closing the window keeps the draft in Brouillons.
struct ComposeView: View {
    let id: UUID
    @Environment(Outbox.self) private var outbox
    @Environment(AccountStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @State private var showsCopies = false
    @State private var problem: String?
    @State private var editor: NoteTextView?

    var body: some View {
        if let draft = outbox.drafts[id] {
            content(draft)
                .navigationTitle(draft.subject.isEmpty ? "Nouveau message" : draft.subject)
                .onAppear { showsCopies = !draft.cc.isEmpty || !draft.bcc.isEmpty }
        } else {
            // Sent or thrown away while the window was closing.
            Color.clear.onAppear { dismiss() }
        }
    }

    private func content(_ draft: Draft) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if store.accounts.count > 1 {
                    FieldRow(label: "De") {
                        Picker("De", selection: binding(\.account, draft)) {
                            ForEach(store.accounts) { Text($0.name.isEmpty ? $0.address : "\($0.name) <\($0.address)>").tag($0.id) }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }
                }
                AddressField(label: "À", text: binding(\.to, draft), account: draft.account) {
                    if !showsCopies {
                        Button("Cc, Cci") { withAnimation(Theme.quick) { showsCopies = true } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondaryText)
                    }
                }
                if showsCopies {
                    AddressField(label: "Cc", text: binding(\.cc, draft), account: draft.account) { EmptyView() }
                    AddressField(label: "Cci", text: binding(\.bcc, draft), account: draft.account) { EmptyView() }
                }
                FieldRow(label: "Objet") {
                    TextField("", text: binding(\.subject, draft), prompt: Text("Objet"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 6)

            if !draft.forwardedFiles.isEmpty {
                ForwardedFiles(files: draft.forwardedFiles) { name in
                    outbox.update(id) { $0.forwardedFiles.removeAll { $0.name == name } }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }

            ComposeEditor(draft: draft, accent: settings.accent, checksSpelling: settings.checksSpelling, checksGrammar: settings.checksGrammar,
                          focusesText: draft.inReplyTo != nil || !draft.to.isEmpty, editor: $editor) { content in
                outbox.update(id) { $0.content = content }
            }
            .background(MessageSurface(drawsFrame: false))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
            .padding(8)
            .padding(.top, 4)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(ChromeBackground().ignoresSafeArea())
        .tint(Theme.accent)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ChromeButton(symbol: "trash", help: "Supprimer le brouillon") {
                    outbox.discard(id)
                    dismiss()
                }
            }
            .plainToolbarItem()
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
            ToolbarItem(placement: .primaryAction) {
                ChromeButton(symbol: "paperclip", help: "Joindre un fichier (⇧⌘A)") { editor?.chooseAttachments() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
            .plainToolbarItem()
            ToolbarItem(placement: .primaryAction) {
                Button("Envoyer") { send() }
                    .primaryButton()
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Envoyer (⌘↩) — il part 10 secondes plus tard, le temps de l'annuler")
            }
            .plainToolbarItem()
        }
        .alert("Pas encore", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK") {}
        } message: {
            Text(problem ?? "")
        }
        .onDisappear { outbox.windowClosed(id) }
    }

    private func send() {
        // What the editor holds right now, the last keystroke included.
        if let editor { outbox.update(id) { $0.content = editor.content } }
        guard let draft = outbox.drafts[id] else { return }
        if let problem = outbox.problem(with: draft) {
            self.problem = problem
            return
        }
        outbox.send(id)
        dismiss()
    }

    /// A field of the draft. While the window closes, the draft may already be sent, thrown away
    /// or put in Brouillons: the field then reads what it showed last (`shown`).
    private func binding<Value>(_ keyPath: WritableKeyPath<Draft, Value>, _ shown: Draft) -> Binding<Value> {
        Binding(get: { (outbox.drafts[id] ?? shown)[keyPath: keyPath] },
                set: { value in outbox.update(id) { $0[keyPath: keyPath] = value } })
    }
}

/// A label in small grey letters, its field, a hairline under them.
private struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 40, alignment: .leading)
                content
                Spacer(minLength: 0)
            }
            .frame(minHeight: 34)
            Rectangle().fill(Theme.stroke).frame(height: 1)
        }
    }
}

/// Addresses, separated by commas; who already wrote to the account is offered as one types.
private struct AddressField<Accessory: View>: View {
    let label: String
    @Binding var text: String
    let account: UUID
    @ViewBuilder let accessory: Accessory
    @Environment(Outbox.self) private var outbox
    @FocusState private var focused: Bool
    @State private var suggestions: [MailAddress] = []
    @State private var highlighted = 0

    var body: some View {
        FieldRow(label: label) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.tab) { complete() }
                .onSubmit { _ = complete() }
            accessory
        }
        .overlay(alignment: .topLeading) {
            if focused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.offset) { index, address in
                        Button { choose(address) } label: {
                            HStack(spacing: 6) {
                                Text(address.name.isEmpty ? address.address : address.name).font(.system(size: 12, weight: .medium))
                                if !address.name.isEmpty {
                                    Text(address.address).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondaryText)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 5).fill(index == highlighted ? Theme.accentSoft : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .frame(width: 360)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surface).shadow(color: Theme.shadow.opacity(0.3), radius: 10, y: 3))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.stroke))
                .offset(x: 50, y: 34)
            }
        }
        .zIndex(focused ? 1 : 0)
        .task(id: text) {
            guard focused else { suggestions = []; return }
            let found = await outbox.suggestions(account: account, for: text)
            // Already written in the field: not offered again.
            suggestions = found.filter { !text.localizedCaseInsensitiveContains($0.address) }
            highlighted = 0
        }
    }

    private func move(_ offset: Int) -> KeyPress.Result {
        guard !suggestions.isEmpty else { return .ignored }
        highlighted = (highlighted + offset + suggestions.count) % suggestions.count
        return .handled
    }

    private func complete() -> KeyPress.Result {
        guard focused, highlighted < suggestions.count else { return .ignored }
        choose(suggestions[highlighted])
        return .handled
    }

    /// The address replaces what was being typed, followed by a comma for the next one.
    private func choose(_ address: MailAddress) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty { parts.removeLast() }
        parts.append(Draft.format([address]))
        text = parts.filter { !$0.isEmpty }.joined(separator: ", ") + ", "
        suggestions = []
    }
}

/// The files of a forwarded message, as cards; ✕ leaves one out.
private struct ForwardedFiles: View {
    let files: [Draft.File]
    let remove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(mimeType: file.contentType) ?? .data))
                            .resizable().frame(width: 16, height: 16)
                        Text(file.name).font(.system(size: 11)).lineLimit(1)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.data.count), countStyle: .file))
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.secondaryText)
                        Button { remove(file.name) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.secondaryText)
                            .help("Ne pas joindre")
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.hover))
                }
            }
        }
    }
}

/// Void Notes' text view, for a message: no title line, no dates, no album; the files dropped
/// or pasted in it are kept in the draft's folder and sent along.
private struct ComposeEditor: NSViewRepresentable {
    let draft: Draft
    let accent: AccentChoice
    let checksSpelling: Bool
    let checksGrammar: Bool
    /// A reply, or a message with its recipient already there: the text takes the keyboard.
    let focusesText: Bool
    @Binding var editor: NoteTextView?
    let onChange: (NoteContent) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let (scrollView, textView) = NoteTextView.makeScrollable()
        textView.startsWithTitle = false
        let directory = draft.attachmentsDirectory
        textView.attachmentsDirectory = directory
        textView.attachFile = { url in Self.copy(url, into: directory) }
        textView.attachData = { data, name in Self.write(data, named: name, into: directory) }
        textView.load(draft.content)
        // A reply: the cursor before the quote, on the blank line left for it.
        if focusesText { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        textView.takesFocusWhenShown = focusesText
        DispatchQueue.main.async { editor = textView }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NoteTextView else { return }
        if textView.accent != accent { textView.accent = accent }
        textView.setProofreading(spelling: checksSpelling, grammar: checksGrammar)
        textView.onChange = { [weak textView] in
            if let textView { onChange(textView.content) }
        }
    }

    /// A copy of the file in the draft's folder, under a name not yet taken there.
    static func copy(_ url: URL, into directory: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return write(data, named: url.lastPathComponent, into: directory)
    }

    static func write(_ data: Data, named name: String, into directory: URL) -> String? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            number += 1
        }
        do {
            try data.write(to: directory.appendingPathComponent(candidate))
            return candidate
        } catch {
            return nil
        }
    }
}
