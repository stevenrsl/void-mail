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
