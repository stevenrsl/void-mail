import SwiftUI

/// The text view of the message being written, for the controls beside it: the formatting
/// panel acts on it, the photos go into it. Also whether one is typing, for the controls to step
/// aside meanwhile, as in Void Notes.
@MainActor @Observable
final class EditorHandle {
    @ObservationIgnored weak var editor: NoteTextView?
    var writing = false

    /// Posted with the text view as object: ⌘K, the link of the selection.
    static let linkRequest = Notification.Name("app.void.mail.linkRequest")
}

/// A weight offered in the formatting panel and in the Format menu. `weight` nil: the weight the
/// paragraph has by itself.
struct WeightChoice: Identifiable {
    let label: String
    let weight: NoteWeight?
    let font: Font.Weight
    var id: String { label }

    static let all = [
        WeightChoice(label: "Léger", weight: .light, font: .light),
        WeightChoice(label: "Normal", weight: nil, font: .regular),
        WeightChoice(label: "Moyen", weight: .medium, font: .medium),
        WeightChoice(label: "Semi-gras", weight: .semibold, font: .semibold),
        WeightChoice(label: "Gras", weight: .bold, font: .bold),
    ]
}

/// Button that opens the formatting panel.
struct FormatButton: View {
    let handle: EditorHandle
    @State private var showing = false
    /// Opened by ⌘K: the address of the link takes the keyboard.
    @State private var forLink = false

    var body: some View {
        ChromeButton(symbol: "textformat", help: "Mise en forme", active: showing) { showing.toggle() }
            .popover(isPresented: $showing, arrowEdge: .bottom) { FormatPanel(handle: handle, focusesLink: forLink) }
            // Panel closed: back to writing.
            .onChange(of: showing) { _, showing in
                if !showing {
                    forLink = false
                    handle.editor?.focus()
                }
            }
            // ⌘K (Format → « Lien… ») in this message's window.
            .onReceive(NotificationCenter.default.publisher(for: EditorHandle.linkRequest)) { note in
                guard let editor = handle.editor, note.object as AnyObject? === editor else { return }
                forLink = true
                showing = true
            }
            #if DEBUG
            .onAppear {
                guard UserDefaults.standard.bool(forKey: "showFormat") else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showing = true }
            }
            #endif
    }
}

/// What the text of a message can be given (Void Notes' panel): a paragraph style, bold, italic, yellow highlighting,
/// struck through, code, a weight, lists (to check, bulleted, numbered) and their indentation, a
/// quote, a divider, a link. It acts on the selection,
/// or on what is typed next — the
/// same as the marks typed in the text and the Format menu. No color to choose.
struct FormatPanel: View {
    let handle: EditorHandle
    /// The address of the link takes the keyboard when the panel opens.
    var focusesLink = false
    /// Changes after each action: the panel reads the text view's state again.
    @State private var revision = 0
    /// The address typed for the link of the selection.
    @State private var address = ""
    @State private var wrongAddress = false
    @FocusState private var addressFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let _ = revision
        let editor = handle.editor
        let block = editor?.currentBlock, weight = editor?.currentWeight
        VStack(alignment: .leading, spacing: 12) {
            section("Style") {
                VStack(spacing: 1) {
                    StyleRow(name: "Titre", size: 20, weight: .bold, shortcut: "⌥⌘1", selected: block == .title) { act { $0.setBlock(.title) } }
                    StyleRow(name: "Sous-titre", size: 16, weight: .semibold, shortcut: "⌥⌘2", selected: block == .heading) { act { $0.setBlock(.heading) } }
                    StyleRow(name: "Intertitre", size: 14, weight: .semibold, shortcut: "⌥⌘3", selected: block == .subheading) { act { $0.setBlock(.subheading) } }
                    StyleRow(name: "Texte", size: 13, weight: .regular, shortcut: "⌥⌘0", selected: block == nil) { act { $0.setBlock(nil) } }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.hover))
            }
            section("Caractères") {
                HStack(spacing: 4) {
                    Tile(help: "Gras (⌘B)", selected: weight == .bold) { act { $0.toggleBold() } } label: {
                        Text("G").font(.system(size: 14, weight: .bold))
                    }
                    Tile(help: "Italique (⌘I)", selected: editor?.isItalic == true) { act { $0.toggleItalic() } } label: {
                        Text("I").font(.system(size: 14, design: .serif)).italic()
                    }
                    Tile(help: "Barré (⇧⌘X)", selected: editor?.isStruck == true) { act { $0.toggleStrike() } } label: {
                        Text("S").font(.system(size: 14)).strikethrough()
                    }
                    Tile(help: "Code", selected: editor?.isCode == true) { act { $0.toggleCode() } } label: {
                        symbol("chevron.left.forwardslash.chevron.right")
                    }
                    Tile(help: "Surligner (⇧⌘E)", selected: editor?.isHighlighted == true) { act { $0.toggleHighlight() } } label: {
                        Text("Surligner")
                            .font(.system(size: 11.5, weight: .medium))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(Theme.highlight))
                    }
                    .frame(width: 76)
                }
            }
            section("Graisse", detail: WeightChoice.all.first { $0.weight == weight }?.label) {
                HStack(spacing: 4) {
                    ForEach(WeightChoice.all) { choice in
                        Tile(help: choice.label, selected: choice.weight == weight) { act { $0.setWeight(choice.weight) } } label: {
                            Text("Aa").font(.system(size: 14, weight: choice.font))
                        }
                    }
                }
            }
            section("Paragraphe") {
                HStack(spacing: 4) {
                    Tile(help: "Liste à cocher (⌥⌘6)", selected: false) { act { $0.toggleList(.checklist) } } label: { symbol("checklist") }
                    Tile(help: "Liste à puces (⌥⌘7)", selected: false) { act { $0.toggleList(.bullet) } } label: { symbol("list.bullet") }
                    Tile(help: "Liste numérotée (⌥⌘8)", selected: false) { act { $0.toggleList(.numbered) } } label: { symbol("list.number") }
                    Tile(help: "Retrait (Tab, ⌘]) — ⇧Tab ou ⌘[ pour revenir", selected: false) { act { $0.changeIndent(by: 1) } } label: { symbol("increase.indent") }
                    Tile(help: "Citation (⌥⌘9)", selected: block == .quote) { act { $0.setBlock(block == .quote ? nil : .quote) } } label: { symbol("text.quote") }
                    Tile(help: "Séparateur", selected: false) { act { $0.insertDivider() } } label: { symbol("minus") }
                }
            }
            section("Lien", detail: wrongAddress ? "Adresse non reconnue" : nil) {
                let link = editor?.currentLink
                HStack(spacing: 4) {
                    TextField("Adresse du lien", text: $address, prompt: Text(verbatim: "void.app, nom@exemple.fr…"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .padding(.horizontal, 9)
                        .frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.hover))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(addressFocused ? Theme.accent.opacity(0.6) : .clear))
                        .focused($addressFocused)
                        .onSubmit(applyLink)
                        .onChange(of: address) { wrongAddress = false }
                        .accessibilityLabel("Adresse du lien")
                    Tile(help: link == nil ? "Ajouter le lien (↩)" : "Changer l'adresse (↩)", selected: false, action: applyLink) { symbol("link") }
                        .frame(width: 34)
                    if link != nil {
                        Tile(help: "Retirer le lien", selected: false) {
                            act { $0.setLink(nil) }
                            address = ""
                        } label: { symbol("xmark") }
                            .frame(width: 34)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 252)
        .tint(Theme.accent)
        .onAppear {
            address = handle.editor?.currentLink.map { $0.hasPrefix("mailto:") ? String($0.dropFirst(7)) : $0 } ?? ""
            if focusesLink { DispatchQueue.main.async { addressFocused = true } }
        }
    }

    /// The selection becomes a link to the address typed — written itself when nothing is
    /// selected — and the panel closes, back to the text.
    private func applyLink() {
        guard let url = NoteFormat.linkURL(from: address) else {
            wrongAddress = !address.trimmingCharacters(in: .whitespaces).isEmpty
            return
        }
        act { $0.setLink(url) }
        dismiss()
    }

    private func act(_ action: (NoteTextView) -> Void) {
        guard let editor = handle.editor else { return }
        action(editor)
        revision += 1
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 13, weight: .medium))
    }

    /// A group of controls under its name; `detail` says the current choice.
    private func section(_ title: String, detail: String? = nil, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if let detail { Text(detail).foregroundStyle(Theme.accent) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.secondaryText)
            .padding(.horizontal, 4)
            content()
        }
    }
}

/// A paragraph style, written the way it looks, with its shortcut.
private struct StyleRow: View {
    let name: String
    let size: CGFloat
    let weight: Font.Weight
    let shortcut: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(name)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(selected ? Theme.accent : Theme.primaryText)
                Spacer()
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.accent)
                } else {
                    Text(shortcut).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.secondaryText.opacity(hovering ? 1 : 0.6))
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A square control of the panel: on in the accent color.
private struct Tile<Label: View>: View {
    let help: String
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            label
                .foregroundStyle(selected ? Theme.accent : Theme.primaryText)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Theme.accentSoft : Theme.hover))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(hovering && !selected ? Theme.stroke : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
