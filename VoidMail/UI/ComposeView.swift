import PhotosUI
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
    /// The text view, for the controls beside it and for « Envoyer ».
    @State private var handle = EditorHandle()

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
                          focusesText: focusesText(draft), handle: handle, discard: discard) { content in
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
            if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
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
        // The pointer moves, a click, a scroll: the controls that faded while typing come back.
        .background(PointerWatcher { if handle.writing { handle.writing = false } })
        .onDisappear { outbox.windowClosed(id) }
    }

    /// A reply, or a message with its recipient already there: the text takes the keyboard.
    private func focusesText(_ draft: Draft) -> Bool {
        #if DEBUG
        if UserDefaults.standard.string(forKey: "composeTo") != nil { return false }
        #endif
        return draft.inReplyTo != nil || !draft.to.isEmpty
    }

    /// The draft thrown away, its window closed.
    private func discard() {
        outbox.discard(id)
        dismiss()
    }

    private func send() {
        // What the editor holds right now, the last keystroke included.
        if let editor = handle.editor { outbox.update(id) { $0.content = editor.content } }
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
        // The suggestions go under the field, in the layout: the editor below is an AppKit view,
        // drawn over anything SwiftUI would float above it.
        VStack(alignment: .leading, spacing: 0) {
            FieldRow(label: label) {
                TextField("", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .focused($focused)
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.tab) { complete() }
                    .onKeyPress(.escape) { suggestions.isEmpty ? .ignored : { suggestions = []; return .handled }() }
                    .onSubmit { _ = complete() }
                accessory
            }
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
                .padding(.vertical, 4)
                .padding(.leading, 40)
                .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: suggestions.isEmpty)
        #if DEBUG
        // `-composeTo ca`: the field « À » focused with that typed, for the snapshots.
        .onAppear { if label == "À", UserDefaults.standard.string(forKey: "composeTo") != nil { focused = true } }
        #endif
        .task(id: "\(text)\(focused)") {
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

/// At the end of the text's first line, as by a note's title: formatting, images, files, and
/// the trash that throws the draft away. Faded while typing.
private struct ComposeActions: View {
    let handle: EditorHandle
    let discard: () -> Void
    var floating = false

    var body: some View {
        HStack(spacing: 4) {
            FormatButton(handle: handle)
            PhotoButton(handle: handle)
            ChromeButton(symbol: "paperclip", help: "Joindre un fichier (⇧⌘A)") { handle.editor?.chooseAttachments() }
            ChromeButton(symbol: "trash", help: "Supprimer le brouillon", action: discard)
        }
        .opacity(0.8)
        .padding(NoteTextView.accessoryInset)
        .background {
            if floating {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.stroke))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                    .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: floating)
        .opacity(handle.writing ? 0 : 1)
        .allowsHitTesting(!handle.writing)
        .animation(.easeInOut(duration: handle.writing ? 0.6 : 0.2), value: handle.writing)
    }
}

/// Images, from the photo library or from a file: in the text, sent along like any file.
private struct PhotoButton: View {
    let handle: EditorHandle
    @State private var showsPicker = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Depuis la photothèque", systemImage: "photo.on.rectangle") { showsPicker = true }
            Button("Depuis un fichier…", systemImage: "folder") { handle.editor?.choosePhotos() }
        } label: {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Ajouter des images")
        .accessibilityLabel("Ajouter des images")
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .photosPicker(isPresented: $showsPicker, selection: $picked, maxSelectionCount: 30, matching: .images)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty, let editor = handle.editor else { return }
            picked = []
            Task {
                var names: [String] = []
                for item in items {
                    guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                    let type = item.supportedContentTypes.first { $0.conforms(to: .image) }
                    if let name = editor.attachData?(data, "Photo.\(type?.preferredFilenameExtension ?? "jpg")") { names.append(name) }
                }
                editor.insertAttachments(names, at: editor.selectedRange())
                editor.focus()
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
    let handle: EditorHandle
    let discard: () -> Void
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
        // A new message or a reply: the cursor on the first line, above the signature and the
        // quote. A draft taken up again: at its end, where it was left.
        if draft.replaces == nil { textView.setSelectedRange(NSRange(location: 0, length: 0)) }
        textView.takesFocusWhenShown = focusesText
        handle.editor = textView
        textView.onTyping = { [handle] in if !handle.writing { handle.writing = true } }
        // Void Notes' controls, at the end of the first line; over the text once it has scrolled.
        let actions = NSHostingView(rootView: ComposeActions(handle: handle, discard: discard))
        textView.accessory = actions
        textView.accessoryFloats = { [handle, discard] in actions.rootView = ComposeActions(handle: handle, discard: discard, floating: $0) }
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
