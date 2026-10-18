import SwiftUI

/// The menus: what the window does, with Void's and Void Notes' shortcuts where they mean the same.
struct MailCommands: Commands {
    let model: MailModel
    let settings: AppSettings
    let outbox: Outbox
    @Environment(\.openWindow) private var openWindow

    /// The text being written, in the window in front.
    private var editor: NoteTextView? { NSApp.keyWindow?.firstResponder as? NoteTextView }

    private func open(_ draft: UUID?) {
        if let draft { openWindow(id: "compose", value: draft) }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Nouveau message") {
                if let id = outbox.newDraft(account: model.currentAccount) { openWindow(id: "compose", value: id) }
            }
            .keyboardShortcut("n")
            .disabled(model.currentAccount == nil)
            Divider()
            Button("Ajouter un compte…") { model.addingAccount = true }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        CommandMenu("Message") {
            Button("Répondre") { open(model.replyDraft(all: false)) }
                .keyboardShortcut("r")
                .disabled(!model.canReply)
            Button("Répondre à tous") { open(model.replyDraft(all: true)) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!model.canReply)
            Button("Transférer") { open(model.forwardDraft()) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.canReply)
            Divider()
            Button("Relever") { Task { await model.refresh() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Message suivant") { model.move(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            Button("Message précédent") { model.move(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            Button(model.selectedMessage?.isSeen == false ? "Marquer comme lu" : "Marquer comme non lu") { model.toggleSeen() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(model.selectedMessage == nil)
            Button(model.selectedMessage?.isFlagged == true ? "Désépingler" : "Épingler en tête") { model.togglePinned() }
                .keyboardShortcut("p", modifiers: [.control, .command])
                .disabled(model.selectedMessage == nil)
            Divider()
            Button("Archiver") { model.archiveSelected() }
                .keyboardShortcut("a", modifiers: [.control, .command])
                .disabled(model.selectedMessage == nil)
            Button("Mettre à la corbeille") { model.trashSelected() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedMessage == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(outbox.sending != nil ? "Annuler l'envoi" : model.pending.map { "Annuler « \($0.label) »" } ?? "Annuler") {
                if outbox.sending != nil { outbox.undoSend() } else { model.undo() }
            }
            .keyboardShortcut("z")
            .disabled(model.pending == nil && outbox.sending == nil)
        }
        CommandMenu("Format") {
            Button("Gras") { editor?.toggleBold() }.keyboardShortcut("b")
            Button("Italique") { editor?.toggleItalic() }.keyboardShortcut("i")
            Button("Surligner") { editor?.toggleHighlight() }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Barré") { editor?.toggleStrike() }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Code") { editor?.toggleCode() }
            Divider()
            Button("Titre") { editor?.setBlock(.title) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Sous-titre") { editor?.setBlock(.heading) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Texte") { editor?.setBlock(nil) }.keyboardShortcut("0", modifiers: [.command, .option])
            Divider()
            Button("Liste à cocher") { editor?.toggleList(.checklist) }.keyboardShortcut("6", modifiers: [.command, .option])
            Button("Liste à puces") { editor?.toggleList(.bullet) }.keyboardShortcut("7", modifiers: [.command, .option])
            Button("Liste numérotée") { editor?.toggleList(.numbered) }.keyboardShortcut("8", modifiers: [.command, .option])
            Button("Citation") { editor?.setBlock(editor?.currentBlock == .quote ? nil : .quote) }.keyboardShortcut("9", modifiers: [.command, .option])
            Button("Séparateur") { editor?.insertDivider() }
        }
        CommandGroup(after: .sidebar) {
            Button(settings.showsSidebar ? "Masquer les boîtes" : "Afficher les boîtes") {
                withAnimation(Theme.spring) { settings.showsSidebar.toggle() }
            }
            .keyboardShortcut("s", modifiers: [.control, .command])
            Divider()
            Button("Compte suivant") { model.cycleAccount(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
            Button("Compte précédent") { model.cycleAccount(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
        }
    }
}
