import SwiftUI

/// The menus: what the window does, with Void's and Void Notes' shortcuts where they mean the same.
struct MailCommands: Commands {
    let model: MailModel
    let settings: AppSettings

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Ajouter un compte…") { model.addingAccount = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Message") {
            Button("Relever") { Task { await model.refresh() } }
                .keyboardShortcut("r")
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
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.selectedMessage == nil)
            Button("Mettre à la corbeille") { model.trashSelected() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedMessage == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button(model.pending.map { "Annuler « \($0.label) »" } ?? "Annuler") { model.undo() }
                .keyboardShortcut("z")
                .disabled(model.pending == nil)
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
