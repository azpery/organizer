import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store

    // Clockify
    @AppStorage("clockifyApiKey") private var clockifyKey = ""
    @AppStorage("clockifyWorkspaceId") private var workspaceId = ""
    @State private var workspaces: [CKWorkspace] = []
    @State private var importFrom = Calendar.app.date(byAdding: .year, value: -2, to: Date())!
    @State private var importTo = Date()
    @State private var clockifyBusy = false
    @State private var clockifyMessage: String?

    // Jira
    @AppStorage("jiraBaseURL") private var jiraURL = ""
    @AppStorage("jiraEmail") private var jiraEmail = ""
    @AppStorage("jiraToken") private var jiraToken = ""
    @AppStorage("jiraProjectKey") private var jiraKey = ""
    @AppStorage("jiraDefaultProject") private var jiraDefaultProject = ""
    @AppStorage("profile.name") private var profileName = ""
    @AppStorage("profile.about") private var profileAbout = ""
    @AppStorage("waitingFacet") private var waitingFacet = ""
    @AppStorage("jiraSync") private var jiraSync = true
    @AppStorage("jiraWatch") private var jiraWatch = ""
    @State private var jiraBusy = false
    @State private var jiraMessage: String?

    // GitLab
    @AppStorage("gitlabURL") private var gitlabURL = ""
    @AppStorage("gitlabToken") private var gitlabToken = ""
    @AppStorage("gitlabProjects") private var gitlabProjects = ""
    @State private var gitlabMessage: String?
    @State private var gitlabBusy = false

    // Google
    @AppStorage("googleClientId") private var googleClientId = ""
    @AppStorage("googleClientSecret") private var googleClientSecret = ""
    @AppStorage("workStart") private var workStart = "09:00"
    @AppStorage("workEnd") private var workEnd = "18:30"
    @State private var googleConnected = GoogleAuth.isConnected
    @State private var googleBusy = false
    @State private var googleMessage: String?
    @State private var calendars: [GCalendar] = []
    @State private var selectedCalendars: Set<String> = Set(GoogleCalendar.selectedIds)

    // Billing
    @AppStorage("billing.name") private var bName = ""
    @AppStorage("billing.address") private var bAddress = ""
    @AppStorage("billing.siret") private var bSiret = ""
    @AppStorage("billing.vat") private var bVat = ""
    @AppStorage("billing.email") private var bEmail = ""
    @AppStorage("billing.phone") private var bPhone = ""
    @AppStorage("billing.iban") private var bIban = ""
    @AppStorage("billing.bic") private var bBic = ""
    @AppStorage("billing.rate") private var bRate = 0.0
    @AppStorage("billing.paymentDays") private var bDays = 30
    @AppStorage("billing.prefix") private var bPrefix = "F"
    @AppStorage("billing.template") private var bTemplate = ""
    @AppStorage("billing.nextSeq") private var bNextSeq = 0
    @AppStorage("billing.rounding") private var bRounding = 15
    @AppStorage("billing.mentions") private var bMentions = ""

    // Mail
    @AppStorage("mailEnabled") private var mailEnabled = true
    @AppStorage("mailDays") private var mailDays = 21
    @AppStorage("autoPrep") private var autoPrep = true
    @State private var mailAccounts: [String] = []
    @State private var selectedMailAccounts: Set<String> = Set(MailSource.accounts)

    // Ollama
    @AppStorage("ollamaURL") private var ollamaURL = ""
    @AppStorage("ollamaModel") private var ollamaModel = "qwen3:8b"
    @State private var ollamaModels: [String] = []
    @AppStorage("ollamaContext") private var ollamaContext = 8192
    @AppStorage("ollamaKeepAlive") private var ollamaKeepAlive = "1m"
    @State private var ollamaMessage: String?
    @ObservedObject private var ollamaService = OllamaService.shared

    // API
    @AppStorage("apiPort") private var apiPort = 47821
    @State private var token = Config.apiToken
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Statut") {
                    HStack(spacing: 6) {
                        Circle().fill(store.apiStatus.hasPrefix("Active") ? Color.green : .orange).frame(width: 8, height: 8)
                        Text(store.apiStatus).textSelection(.enabled)
                    }
                }
                LabeledContent("Token") {
                    HStack {
                        Text(token.prefix(10) + "…").font(.body.monospaced()).foregroundStyle(.secondary)
                        Button(copied ? "Copié ✓" : "Copier") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(token, forType: .string)
                            copied = true
                        }
                        Button("Régénérer") {
                            token = Config.regenerateToken()
                            store.writeAPIInfo()
                        }
                    }
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("", value: $apiPort, format: .number.grouping(.never)).frame(width: 80)
                        Button("Redémarrer l'API") { store.startAPI() }
                    }
                }
                Text("URL et token sont écrits dans `~/Library/Application Support/Organizer/api.json` pour que Claude (ou tout script) puisse piloter tes tâches.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("API locale", systemImage: "network")
            }

            Section {
                SecureField("Clé API", text: $clockifyKey, prompt: Text("Clockify › Profil › Paramètres › API"))
                HStack {
                    Picker("Workspace", selection: $workspaceId) {
                        Text("Workspace actif").tag("")
                        ForEach(workspaces) { Text($0.name).tag($0.id) }
                    }
                    Button("Charger") { loadWorkspaces() }.disabled(clockifyKey.isEmpty)
                }
                DatePicker("Importer depuis", selection: $importFrom, displayedComponents: .date)
                DatePicker("Jusqu'au", selection: $importTo, displayedComponents: .date)
                HStack {
                    Button {
                        runClockifyImport()
                    } label: {
                        Label("Importer clients, projets, tâches et temps", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(clockifyKey.isEmpty || clockifyBusy)
                    if clockifyBusy { ProgressView().controlSize(.small) }
                }
                if let clockifyMessage { Text(clockifyMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Relancer l'import met à jour les éléments existants sans créer de doublons.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Clockify", systemImage: "clock.arrow.2.circlepath")
            }

            Section {
                TextField("Prénom", text: $profileName, prompt: Text("par défaut : celui de la facturation"))
                TextField("Présentation", text: $profileAbout, prompt: Text("ex. développeuse freelance ; clients : A, B ; projet perso C"), axis: .vertical)
                    .lineLimit(1...4)
                TextField("Facette « en attente »", text: $waitingFacet, prompt: Text("⏳ En attente"))
                Text("La présentation est donnée à l'assistant local (Ollama) pour qu'il connaisse ton contexte. Les tâches de la facette « en attente » sont moins prioritaires dans les suggestions du jour.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Profil", systemImage: "person.crop.circle")
            }

            Section {
                TextField("URL Jira", text: $jiraURL, prompt: Text("https://ton-site.atlassian.net"))
                TextField("E-mail", text: $jiraEmail)
                SecureField("API token", text: $jiraToken, prompt: Text("id.atlassian.com › Sécurité › Tokens d'API"))
                TextField("Clé du projet", text: $jiraKey, prompt: Text("ABC"))
                Picker("Projet des tickets importés", selection: $jiraDefaultProject) {
                    Text("Aucun").tag("")
                    ForEach(store.activeProjects) { Text($0.name).tag($0.name) }
                    if !jiraDefaultProject.isEmpty && !store.activeProjects.contains(where: { $0.name == jiraDefaultProject }) {
                        Text(jiraDefaultProject).tag(jiraDefaultProject)
                    }
                }
                Toggle("Répercuter mes changements dans Jira (statut, titre, échéance)", isOn: $jiraSync)
                TextField("Autres projets à surveiller", text: $jiraWatch, prompt: Text("ex. RC (notification des nouveaux tickets, sans import)"))
                Text("Les nouveaux tickets \(jiraKey.uppercased()) sont importés et notifiés automatiquement toutes les 10 minutes\(store.jiraLastCheck.map { " · dernière vérification à \(Fmt.time($0))" } ?? "").")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        runJiraImport()
                    } label: {
                        Label("Importer mes tickets \(jiraKey.uppercased())", systemImage: "ticket.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!Jira.isConfigured || jiraKey.isEmpty || jiraBusy)
                    if jiraBusy { ProgressView().controlSize(.small) }
                }
                if let jiraMessage { Text(jiraMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
                Text("Les tâches dont le nom contient une clé (ex. « \(Jira.sampleKey(9)) ») sont reliées automatiquement au ticket.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Jira", systemImage: "link")
            }

            Section {
                TextField("URL GitLab", text: $gitlabURL, prompt: Text("https://gitlab.com"))
                SecureField("Token d'accès personnel", text: $gitlabToken, prompt: Text("scope read_api"))
                TextField("Projets", text: $gitlabProjects, prompt: Text("groupe/projet, groupe/autre-projet"))
                Text("Obligatoire avec un token fine-grained limité à des projets : indique les chemins des dépôts (ex. groupe/depot).")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button {
                        gitlabBusy = true
                        Task {
                            do {
                                // Probing MRs directly: only "Merge Request: Read" is strictly needed.
                                _ = try await GitLab.mergeRequests(for: Jira.projectKey + "-1")
                                    // fine-grained tokens: project-level access only
                                let user = try? await GitLab.currentUser()
                                await store.refreshMergeRequests()
                                let n = store.mergeRequests.values.reduce(0) { $0 + $1.count }
                                gitlabMessage = "✓ Connecté\(user.map { " (@\($0))" } ?? "") · \(n) MR liées à des tâches"
                            } catch {
                                gitlabMessage = "Erreur : " + ((error as? APIError)?.message ?? error.localizedDescription)
                            }
                            gitlabBusy = false
                        }
                    } label: { Label("Tester et rafraîchir les MR", systemImage: "arrow.triangle.pull") }
                    .disabled(gitlabToken.isEmpty || gitlabBusy)
                    if gitlabBusy { ProgressView().controlSize(.small) }
                }
                if let gitlabMessage { Text(gitlabMessage).font(.callout).foregroundStyle(.secondary) }
                Text("Les MR qui mentionnent la clé Jira d'une tâche (titre, description ou branche) sont affichées sur sa carte. Rafraîchi toutes les 10 min.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("GitLab", systemImage: "arrow.triangle.pull")
            }

            AppleCalendarSection()

            Section {
                if googleConnected {
                    LabeledContent("Compte") {
                        HStack {
                            Label(GoogleAuth.email ?? "Connecté", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                            Button("Déconnecter") {
                                GoogleAuth.signOut(); googleConnected = false; calendars = []
                                Task { await store.refreshCalendar() }
                            }
                        }
                    }
                    if !calendars.isEmpty {
                        LabeledContent("Agendas affichés") {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(calendars) { c in
                                    Toggle(isOn: Binding(
                                        get: { selectedCalendars.isEmpty ? c.primary : selectedCalendars.contains(c.id) },
                                        set: { on in
                                            if selectedCalendars.isEmpty { selectedCalendars = Set(calendars.filter(\.primary).map(\.id)) }
                                            if on { selectedCalendars.insert(c.id) } else { selectedCalendars.remove(c.id) }
                                            GoogleCalendar.selectedIds = Array(selectedCalendars)
                                            Task { await store.refreshCalendar() }
                                        })) {
                                        HStack(spacing: 6) {
                                            Circle().fill(Color(hex: c.color)).frame(width: 8, height: 8)
                                            Text(c.summary)
                                        }
                                    }
                                    .toggleStyle(.checkbox)
                                }
                            }
                        }
                    }
                } else {
                    TextField("Client ID", text: $googleClientId, prompt: Text("xxxx.apps.googleusercontent.com"))
                    SecureField("Client secret", text: $googleClientSecret)
                    HStack {
                        Button {
                            googleBusy = true
                            googleMessage = "Termine la connexion dans ton navigateur…"
                            Task {
                                do {
                                    let mail = try await GoogleAuth.signIn()
                                    googleConnected = true
                                    googleMessage = "✓ Connecté (\(mail))"
                                    loadCalendars()
                                    await store.refreshCalendar()
                                } catch {
                                    googleMessage = "Erreur : " + ((error as? APIError)?.message ?? error.localizedDescription)
                                }
                                googleBusy = false
                            }
                        } label: { Label("Se connecter à Google", systemImage: "person.badge.key.fill") }
                        .buttonStyle(.borderedProminent)
                        .disabled(googleClientId.isEmpty || googleBusy)
                        Button("Ouvrir la console Google Cloud") {
                            NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                        }
                    }
                    Text("1. Crée un projet, active « Google Calendar API ». 2. Écran de consentement : type Externe, ajoute ton adresse comme utilisateur test. 3. Identifiants › Créer › ID client OAuth › Application de bureau, puis colle l'ID et le secret ici.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let googleMessage { Text(googleMessage).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    TextField("Début de journée", text: $workStart).frame(width: 160)
                    TextField("Fin de journée", text: $workEnd).frame(width: 160)
                }
                Text("Les heures de travail servent à calculer ton temps libre et à placer le plan du jour.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Google Agenda", systemImage: "calendar")
            }
            .onAppear { if googleConnected { loadCalendars() } }

            Section {
                Toggle("Lire mes mails dans Apple Mail (stockés en local, utilisés par Ollama)", isOn: $mailEnabled)
                Stepper("Fenêtre : \(mailDays) derniers jours", value: $mailDays, in: 3...90, step: 7)
                if !mailAccounts.isEmpty {
                    LabeledContent("Comptes") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(mailAccounts, id: \.self) { a in
                                Toggle(a, isOn: Binding(
                                    get: { selectedMailAccounts.isEmpty || selectedMailAccounts.contains(a) },
                                    set: { on in
                                        if selectedMailAccounts.isEmpty { selectedMailAccounts = Set(mailAccounts) }
                                        if on { selectedMailAccounts.insert(a) } else { selectedMailAccounts.remove(a) }
                                        UserDefaults.standard.set(Array(selectedMailAccounts), forKey: "mailAccounts")
                                    }))
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
                HStack {
                    Button {
                        Task { await store.syncMails() }
                    } label: { Label("Synchroniser maintenant", systemImage: "arrow.triangle.2.circlepath") }
                    .disabled(store.mailSyncing || !mailEnabled)
                    if store.mailSyncing { ProgressView().controlSize(.small) }
                    if let st = store.mailStatus { Text(st).font(.callout).foregroundStyle(.secondary) }
                }
                Toggle("Préparer automatiquement mes réunions 1 h avant (Ollama)", isOn: $autoPrep)
            } header: {
                Label("Mails et préparation des réunions", systemImage: "envelope")
            }
            .task { mailAccounts = (try? await MailSource.listAccounts()) ?? [] }

            Section {
                TextField("URL", text: $ollamaURL, prompt: Text("http://localhost:11434"))
                HStack {
                    Picker("Modèle", selection: $ollamaModel) {
                        ForEach(Array(Set(ollamaModels + [ollamaModel])).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Button("Actualiser") { loadOllama() }
                }
                HStack {
                    OllamaToggle()
                    Spacer()
                    if let ollamaMessage { Text(ollamaMessage).font(.callout).foregroundStyle(.secondary) }
                }
                Picker("Contexte", selection: $ollamaContext) {
                    Text("4 096 jetons (léger)").tag(4096)
                    Text("8 192 jetons (recommandé)").tag(8192)
                    Text("16 384 jetons (+1,2 Go)").tag(16384)
                }
                Picker("Garder en mémoire", selection: $ollamaKeepAlive) {
                    Text("1 minute").tag("1m"); Text("5 minutes").tag("5m"); Text("30 minutes").tag("30m"); Text("Toujours").tag("-1")
                }
                Text("Mémoire ≈ taille du modèle + contexte (qwen3:8b : ~5 Go + ~1,2 Go pour 8 192 jetons). Libérée après le délai choisi.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Ollama n'est jamais lancé automatiquement : active-le ici ou depuis l'Assistant quand tu en as besoin. Tout reste en local.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Ollama", systemImage: "cpu")
            }
            .onAppear { loadOllama() }
            .onChange(of: ollamaService.running) { _, _ in loadOllama() }

            Section {
                TextField("Nom / raison sociale", text: $bName, prompt: Text("Prénom Nom EI"))
                TextField("Adresse", text: $bAddress, prompt: Text("Rue, code postal, ville"), axis: .vertical).lineLimit(2...4)
                HStack { TextField("SIRET", text: $bSiret); TextField("N° TVA", text: $bVat) }
                HStack { TextField("E-mail", text: $bEmail); TextField("Téléphone", text: $bPhone) }
                HStack { TextField("IBAN", text: $bIban); TextField("BIC", text: $bBic).frame(width: 160) }
                HStack {
                    TextField("Taux horaire par défaut (€ HT)", value: $bRate, format: .number)
                    Stepper("Paiement à \(bDays) jours", value: $bDays, in: 0...90, step: 15)
                }
                HStack {
                    TextField("Format du n°", text: $bTemplate, prompt: Text("F{YY}{SEQ5}")).frame(width: 200)
                        .help("{YYYY} ou {YY} = année, {SEQ3} à {SEQ6} = compteur annuel")
                    TextField("Prochain n° (optionnel)", value: $bNextSeq, format: .number.grouping(.never)).frame(width: 220)
                    Picker("Arrondi", selection: $bRounding) {
                        Text("Minute").tag(1); Text("5 min").tag(5); Text("15 min").tag(15); Text("30 min").tag(30); Text("1 h").tag(60)
                    }
                    .fixedSize()
                }
                TextField("Mentions complémentaires", text: $bMentions, axis: .vertical).lineLimit(1...3)
                Text("Numérotation : \(store.nextInvoiceNumber()) pour la prochaine facture. Les PDF sont rangés dans Documents › Factures.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Label("Facturation", systemImage: "doc.text")
            }

            Section {
                FacetManager()
            } header: {
                Label("Facettes", systemImage: "tag")
            }

            Section {
                LabeledContent("Base de données") {
                    Button("Afficher dans le Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([store.supportDir.appendingPathComponent("organizer.sqlite")])
                    }
                }
                LabeledContent("Contenu", value: "\(store.projects.count) projets · \(store.tasks.count) tâches · \(store.entries.count) entrées")
            } header: {
                Label("Données", systemImage: "externaldrive")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Réglages")
    }

    private func loadCalendars() {
        Task {
            do { calendars = try await GoogleCalendar.calendars() }
            catch { googleMessage = "Erreur : " + ((error as? APIError)?.message ?? error.localizedDescription) }
        }
    }

    private func loadOllama() {
        Task {
            do {
                ollamaModels = try await Ollama.models()
                ollamaMessage = "✓ Connecté · \(ollamaModels.count) modèle(s)"
            } catch {
                ollamaMessage = "Ollama ne répond pas"
            }
        }
    }

    private func loadWorkspaces() {
        Task {
            do { workspaces = try await ClockifyClient(apiKey: clockifyKey).workspaces() }
            catch { clockifyMessage = describe(error) }
        }
    }

    private func runClockifyImport() {
        clockifyBusy = true
        clockifyMessage = "Import en cours…"
        Task {
            do {
                let end = Calendar.app.date(byAdding: .day, value: 1, to: Calendar.app.startOfDay(for: importTo))!
                let r = try await ClockifyImporter.run(store: store, from: Calendar.app.startOfDay(for: importFrom), to: end)
                clockifyMessage = "✓ " + r.description
            } catch {
                clockifyMessage = "Erreur : " + describe(error)
            }
            clockifyBusy = false
        }
    }

    private func runJiraImport() {
        jiraBusy = true
        Task {
            do { jiraMessage = "✓ " + (try await Jira.importIssues(store: store)) }
            catch { jiraMessage = "Erreur : " + describe(error) }
            jiraBusy = false
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? APIError)?.message ?? error.localizedDescription
    }
}

struct FacetManager: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(store.allLabels, id: \.name) { l in
                HStack(spacing: 2) {
                    LabelChip(name: l.name, selected: true, count: l.count)
                    Button { store.removeFacet(l.name) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Supprimer la facette (retirée de toutes les tâches)")
                }
            }
        }
        TextField("Nouvelle facette", text: $newName, prompt: Text("ex. Client A"))
            .onSubmit { store.addFacet(newName); newName = "" }
    }
}

struct AppleCalendarSection: View {
    @EnvironmentObject var store: Store
    @State private var enabled = AppleCalendar.enabled
    @State private var authorized = AppleCalendar.authorized
    @State private var calendars: [AppleCalendar.Cal] = []
    @State private var selected: Set<String> = Set(AppleCalendar.selectedIds)

    var body: some View {
        Section {
            Toggle("Lire le Calendrier macOS", isOn: $enabled)
                .onChange(of: enabled) { _, v in AppleCalendar.enabled = v; Task { await store.refreshCalendar() } }
            LabeledContent("Accès") {
                HStack {
                    Label(AppleCalendar.statusLabel, systemImage: authorized ? "checkmark.seal.fill" : "lock")
                        .foregroundStyle(authorized ? .green : .secondary)
                    if !authorized {
                        if AppleCalendar.status == .notDetermined {
                            Button("Autoriser") {
                                Task {
                                    authorized = await AppleCalendar.requestAccess()
                                    calendars = AppleCalendar.calendars()
                                    await store.refreshCalendar()
                                }
                            }
                        } else {
                            Button("Ouvrir Réglages Système") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                            }
                        }
                    }
                }
            }
            if authorized && enabled && !calendars.isEmpty {
                LabeledContent("Agendas lus") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Dictionary(grouping: calendars, by: \.source).sorted { $0.key < $1.key }, id: \.key) { source, cals in
                            Text(source).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                            ForEach(cals) { c in
                                Toggle(isOn: Binding(
                                    get: { selected.isEmpty || selected.contains(c.id) },
                                    set: { on in
                                        if selected.isEmpty { selected = Set(calendars.map(\.id)) }
                                        if on { selected.insert(c.id) } else { selected.remove(c.id) }
                                        if selected.count == calendars.count { selected = [] }
                                        AppleCalendar.selectedIds = Array(selected)
                                        Task { await store.refreshCalendar() }
                                    })) {
                                    HStack(spacing: 6) {
                                        Circle().fill(Color(hex: c.color)).frame(width: 8, height: 8)
                                        Text(c.title)
                                    }
                                }
                                .toggleStyle(.checkbox)
                            }
                        }
                    }
                }
            }
            Text("Lit tous les comptes configurés dans l'app Calendrier (iCloud, Google, Exchange…). Pas besoin de connecter Google séparément si ton compte Google y est déjà ; les doublons sont fusionnés.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Label("Calendrier Apple", systemImage: "calendar")
        }
        .onAppear {
            authorized = AppleCalendar.authorized
            calendars = AppleCalendar.calendars()
        }
    }
}
