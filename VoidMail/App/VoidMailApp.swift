import SwiftUI

@main
struct VoidMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var settings = AppSettings.shared
    @State private var store = AccountStore.shared
    @State private var model = MailModel.shared

    init() {
        #if DEBUG
        // A debug launch always shows its window, even if the last one ended with it closed.
        if DebugLaunch.isRequested { UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true]) }
        #endif
    }

    var body: some Scene {
        Window("Void Mail", id: "main") {
            MainWindowView()
                .environment(settings)
                .environment(store)
                .environment(model)
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1100, height: 700)
        .commands { MailCommands(model: model, settings: settings) }

        Settings {
            SettingsView()
                .environment(settings)
                .environment(store)
                .environment(model)
        }
    }
}
