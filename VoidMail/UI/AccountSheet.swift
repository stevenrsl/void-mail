import SwiftUI

/// Adding an account: the address first — the host's servers and its way of signing in follow
/// from it —, then a password or the provider's sign-in page. « Se connecter » reaches both
/// servers and lists the mailboxes before anything is kept.
struct AccountSheet: View {
    @Environment(AccountStore.self) private var store
    @Environment(MailModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var password = ""
    @State private var auth: MailAuth = .password
    @State private var imap = ServerEndpoint(host: "", port: 993, security: .tls)
    @State private var smtp = ServerEndpoint(host: "", port: 465, security: .tls)
    @State private var username = ""
    @State private var showsServers = false
    @State private var presetDomain: String?
    /// One of `customDomainHosts`, chosen for an address on one's own domain.
    @State private var host: ProviderPreset?
    @State private var step: AccountCheck.Step?
    @State private var error: String?
    @State private var task: Task<Void, Never>?

    private var preset: ProviderPreset { host ?? ProviderDirectory.preset(for: address) }
    private var addressIsValid: Bool {
        let parts = address.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !address.contains(" ")
    }

    private var canConnect: Bool {
        guard addressIsValid, step == nil, imap.isAllowed, smtp.isAllowed, !imap.host.isEmpty, !smtp.host.isEmpty else { return false }
        switch auth {
        case .password: return !password.isEmpty
        case .oauth(let provider): return provider.isConfigured
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VoidLogo(size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ajouter un compte").font(.system(size: 15, weight: .semibold))
                    Text("IMAP et SMTP. Le mot de passe va dans le trousseau de ce Mac, nulle part ailleurs.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondaryText)
                }
            }
            .padding(.bottom, 14)

            Form {
                TextField("Adresse", text: $address, prompt: Text("vous@exemple.fr"))
                    .textContentType(.emailAddress)
                    .onChange(of: address) { applyPreset() }
                TextField("Nom", text: $name, prompt: Text("Le nom affiché à vos destinataires"))

                if preset.auths.count > 1 {
                    Picker("Connexion", selection: $auth) {
                        ForEach(preset.auths, id: \.self) { Text($0.label).tag($0) }
                    }
                    .onChange(of: auth) { useProviderServers() }
                }
                switch auth {
                case .password:
                    SecureField(preset.name == "Proton Mail Bridge" ? "Mot de passe de Bridge" : "Mot de passe d'application", text: $password)
                    if let help = preset.appPasswordHelp {
                        Text(help).font(.caption).foregroundStyle(.secondary)
                    }
                case .oauth(let provider):
                    LabeledContent("Connexion") {
                        Text(provider.isConfigured ? "Page de connexion \(provider.label), à l'étape suivante" : "Indisponible")
                            .foregroundStyle(.secondary)
                    }
                    if !provider.isConfigured {
                        Text(provider.unconfiguredReason).font(.caption).foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup(isExpanded: $showsServers) {
                    if !ProviderDirectory.preset(for: address).isKnown {
                        Picker("Hébergeur", selection: Binding(get: { host?.name ?? "" }, set: { name in useHost(ProviderDirectory.customDomainHosts.first { $0.name == name }) })) {
                            Text("Autre").tag("")
                            ForEach(ProviderDirectory.customDomainHosts, id: \.name) { Text($0.name).tag($0.name) }
                        }
                    }
                    TextField("Identifiant", text: $username, prompt: Text(address))
                    ServerFields(title: "Réception (IMAP)", endpoint: $imap, imap: true)
                    ServerFields(title: "Envoi (SMTP)", endpoint: $smtp, imap: false)
                } label: {
                    Text(addressIsValid ? (preset.isKnown ? "Serveurs de \(preset.name)" : "Serveurs (à vérifier)") : "Serveurs")
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .padding(.horizontal, -20)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 10)
            }

            HStack {
                if let step {
                    ProgressView().controlSize(.small)
                    Text(step.label).font(.system(size: 12)).foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                Button("Annuler") {
                    task?.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Se connecter") { connect() }
                    .primaryButton()
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConnect)
            }
        }
        .padding(20)
        .frame(width: 480)
        .tint(Theme.accent)
        .onAppear {
            #if DEBUG
            if let address = UserDefaults.standard.string(forKey: "address") { self.address = address }
            #endif
            applyPreset()
        }
    }

    /// A new domain in the address: its host's servers and preferred way of signing in (what
    /// was corrected by hand stays while the domain does).
    private func applyPreset() {
        let domain = address.split(separator: "@").last.map { String($0).lowercased() } ?? ""
        guard domain != presetDomain else { return }
        presetDomain = domain
        host = nil
        let preset = self.preset
        auth = preset.preferredAuth
        imap = preset.imap
        smtp = preset.smtp
        if !preset.isKnown, addressIsValid { showsServers = true }
        useProviderServers()
    }

    /// An address on one's own domain, at a host that serves those: its servers and sign-in.
    private func useHost(_ chosen: ProviderPreset?) {
        host = chosen
        let preset = self.preset
        auth = preset.preferredAuth
        imap = preset.imap
        smtp = preset.smtp
        useProviderServers()
    }

    /// Signing in with Microsoft (Microsoft 365 on one's own domain): Microsoft's servers.
    private func useProviderServers() {
        if case .oauth(let provider) = auth {
            imap = provider.imap
            smtp = provider.smtp
        }
    }

    private func connect() {
        error = nil
        var account = MailAccount(name: name.trimmingCharacters(in: .whitespaces),
                                  address: address.trimmingCharacters(in: .whitespaces).lowercased(), preset: preset)
        account.auth = auth
        account.imap = imap
        account.smtp = smtp
        account.username = username.isEmpty ? account.address : username
        let candidate = account
        let secret = password
        task = Task {
            do {
                if case .password = candidate.auth { try Keychain.savePassword(secret, for: candidate.id) }
                let checked = try await AccountCheck.run(candidate) { step = $0 }
                store.save(checked)
                model.select(checked)
                model.watchInboxes()
                dismiss()
            } catch {
                // Nothing kept: the keychain item goes with the failed attempt.
                Keychain.delete(for: candidate.id)
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                step = nil
            }
        }
    }
}

/// Host, port and security of one server; changing the security moves the port to its usual one.
private struct ServerFields: View {
    let title: String
    @Binding var endpoint: ServerEndpoint
    let imap: Bool

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("Serveur", text: $endpoint.host, prompt: Text(imap ? "imap.exemple.fr" : "smtp.exemple.fr"))
                    .labelsHidden()
                TextField("Port", value: $endpoint.port, format: .number.grouping(.never))
                    .labelsHidden()
                    .frame(width: 52)
                Picker("Chiffrement", selection: Binding(get: { endpoint.security }, set: { security in
                    endpoint.security = security
                    endpoint.port = ProviderDirectory.defaultPort(imap: imap, security: security)
                })) {
                    ForEach(ConnectionSecurity.allCases) { Text($0 == .none ? "Aucun" : $0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 104)
            }
        }
        if !endpoint.isAllowed {
            Text(MailError.insecure.errorDescription ?? "").font(.caption).foregroundStyle(Theme.danger)
        }
    }
}
