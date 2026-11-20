import SwiftUI
import UniformTypeIdentifiers

struct InvoicesView: View {
    @EnvironmentObject var store: Store
    @AppStorage("invoices.selected") private var selectedId = ""
    @State private var statusFilter: InvoiceStatus?
    @State private var showNew = false

    private var list: [Invoice] {
        store.invoices.filter { inv in
            (statusFilter == nil || inv.status == statusFilter)
                && (store.client(inv.clientId).map(store.clientInFacets) ?? store.activeFacets.isEmpty)
        }
    }

    var body: some View {
        let items = list
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                summary(items).padding(14)
                Picker("", selection: $statusFilter) {
                    Text("Toutes").tag(InvoiceStatus?.none)
                    ForEach(InvoiceStatus.allCases) { Text($0.label).tag(Optional($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 14).padding(.bottom, 8)
                if items.isEmpty {
                    Spacer()
                    EmptyState(icon: "doc.text", title: "Aucune facture", message: "Crée une facture à partir de ton temps passé.")
                    Spacer()
                } else {
                    List(selection: Binding(get: { selectedId.isEmpty ? nil : selectedId }, set: { selectedId = $0 ?? "" })) {
                        ForEach(items) { inv in InvoiceRow(invoice: inv).tag(inv.id) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                }
            }
            .frame(width: 320)
            .background(Color.primary.opacity(0.025))

            Divider()

            if let inv = store.invoice(selectedId) {
                InvoiceEditor(invoice: inv).id(inv.id)
            } else {
                EmptyState(icon: "doc.text.magnifyingglass", title: "Sélectionne ou crée une facture")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Factures")
        .toolbar {
            Button { showNew = true } label: { Label("Nouvelle facture", systemImage: "plus") }
                .disabled(store.clients.isEmpty)
                .help(store.clients.isEmpty ? "Crée d'abord un client (Configuration › Clients)" : "Facturer du temps passé")
        }
        .sheet(isPresented: $showNew) {
            NewInvoiceSheet { inv in selectedId = inv.id }.environmentObject(store)
        }
    }

    private func summary(_ items: [Invoice]) -> some View {
        let year = Calendar.app.component(.year, from: Date())
        let thisYear = store.invoices.filter { Calendar.app.component(.year, from: $0.issueDate) == year && $0.status != .draft }
        let unpaid = store.invoices.filter { $0.status == .sent }
        return HStack(spacing: 10) {
            mini("Facturé \(year)", Billing.money(thisYear.reduce(0) { $0 + $1.subtotal }, "EUR") + " HT", .blue)
            mini("En attente", Billing.money(unpaid.reduce(0) { $0 + $1.total }, "EUR"), unpaid.contains { $0.dueDate < Date() } ? .red : .orange)
        }
    }

    private func mini(_ title: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.08)))
    }
}

struct InvoiceRow: View {
    @EnvironmentObject var store: Store
    let invoice: Invoice

    var body: some View {
        let overdue = invoice.status == .sent && invoice.dueDate < Date()
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(invoice.number).font(.body.weight(.semibold).monospacedDigit())
                Spacer()
                Text(Billing.money(invoice.total, invoice.currency)).font(.callout.weight(.semibold).monospacedDigit())
            }
            HStack(spacing: 6) {
                Text(store.client(invoice.clientId)?.name ?? "Client supprimé").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Pill(text: overdue ? "En retard" : invoice.status.label, color: overdue ? .red : invoice.status.color, systemImage: invoice.status.icon)
            }
            Text("\(Fmt.date(invoice.issueDate)) · \(Billing.number(invoice.hours)) h").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

/// Wizard: pick a client and a period, preview the billable time, create a draft.
struct NewInvoiceSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    let onCreate: (Invoice) -> Void

    @State private var clientId: String = ""
    @State private var preset: ReportPreset = .lastMonth
    @State private var from: Date = ReportPreset.lastMonth.range().0
    @State private var to: Date = ReportPreset.lastMonth.range().1
    @State private var grouping: InvoiceGrouping = .task
    @State private var error: String?

    private var rangeEnd: Date { Calendar.app.date(byAdding: .day, value: 1, to: Calendar.app.startOfDay(for: to))! }

    var body: some View {
        let entries = clientId.isEmpty ? [] : store.billableEntries(clientId: clientId, from: Calendar.app.startOfDay(for: from), to: rangeEnd)
        let hours = entries.reduce(0) { $0 + $1.duration } / 3600
        let rate = store.client(clientId).map(store.rate(for:)) ?? 0
        VStack(spacing: 0) {
            Text("Nouvelle facture").font(.title2.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .top], 22)
            Form {
                Picker("Client", selection: $clientId) {
                    Text("Choisir…").tag("")
                    ForEach(store.clients) { Text($0.name).tag($0.id) }
                }
                if let c = store.client(clientId), store.projects(of: c.id).isEmpty {
                    Label("Ce client n'a aucun projet rattaché (Configuration › Clients).", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.callout)
                }
                Picker("Période", selection: $preset) {
                    ForEach(ReportPreset.allCases) { Text($0.label).tag($0) }
                }
                DatePicker("Du", selection: Binding(get: { from }, set: { from = $0; preset = .custom }), displayedComponents: .date)
                DatePicker("Au", selection: Binding(get: { to }, set: { to = $0; preset = .custom }), displayedComponents: .date)
                Picker("Lignes", selection: $grouping) {
                    ForEach(InvoiceGrouping.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Section {
                    LabeledContent("Temps non facturé", value: "\(Billing.number(hours, digits: 2)) h · \(entries.count) entrées")
                    LabeledContent("Taux horaire", value: rate > 0 ? Billing.money(rate, store.client(clientId)?.currency ?? "EUR") : "à définir (Réglages ou client)")
                    LabeledContent("Montant estimé HT", value: Billing.money(hours * rate, store.client(clientId)?.currency ?? "EUR"))
                }
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
            }
            .formStyle(.grouped)
            .onChange(of: preset) { _, p in if p != .custom { (from, to) = p.range() } }
            HStack {
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Créer le brouillon") {
                    do {
                        let inv = try store.buildInvoice(clientId: clientId, from: Calendar.app.startOfDay(for: from), to: rangeEnd, grouping: grouping)
                        store.upsertInvoice(inv)
                        onCreate(inv)
                        dismiss()
                    } catch { self.error = (error as? APIError)?.message ?? error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(clientId.isEmpty || entries.isEmpty)
            }
            .padding(22)
        }
        .frame(width: 520, height: 600)
        .onAppear { if clientId.isEmpty { clientId = store.clients.first?.id ?? "" } }
    }
}

struct InvoiceEditor: View {
    @EnvironmentObject var store: Store
    @State private var inv: Invoice
    @State private var mode = 0  // 0 édition, 1 aperçu
    @State private var confirmDelete = false

    init(invoice: Invoice) { _inv = State(initialValue: invoice) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Facture \(inv.number)").font(.title2.weight(.bold))
                    Text(store.client(inv.clientId)?.name ?? "").foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $inv.status) {
                    ForEach(InvoiceStatus.allCases) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                .labelsHidden().fixedSize()
                Picker("", selection: $mode) { Text("Édition").tag(0); Text("Aperçu").tag(1) }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Button { exportPDF() } label: { Label("PDF", systemImage: "arrow.down.doc") }
                    .buttonStyle(.borderedProminent)
                Menu {
                    Button("Supprimer la facture", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
            Divider()

            if mode == 1 {
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 20) {
                        let pages = InvoiceDocument.paginate(inv)
                        ForEach(Array(pages.enumerated()), id: \.offset) { i, slice in
                            InvoiceDocument(invoice: inv, client: store.client(inv.clientId), lines: slice, pageIndex: i, pageCount: pages.count)
                                .environment(\.colorScheme, .light)
                                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                        }
                    }
                    .padding(30)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.primary.opacity(0.05))
            } else {
                editForm
            }
        }
        .onChange(of: inv) { _, new in store.upsertInvoice(new) }
        .confirmationDialog("Supprimer la facture \(inv.number) ?", isPresented: $confirmDelete) {
            Button("Supprimer", role: .destructive) { store.deleteInvoice(inv.id) }
        } message: { Text("Le temps inclus redeviendra facturable.") }
    }

    private var editForm: some View {
        Form {
            Section("Informations") {
                TextField("Numéro", text: $inv.number)
                DatePicker("Date d'émission", selection: $inv.issueDate, displayedComponents: .date)
                DatePicker("Échéance", selection: $inv.dueDate, displayedComponents: .date)
                Picker("TVA", selection: $inv.vatMode) {
                    ForEach(VatMode.allCases) { Text($0.label).tag($0) }
                }
                if inv.vatMode.appliesVAT {
                    TextField("Taux de TVA (%)", value: Binding(get: { inv.vatRate * 100 }, set: { inv.vatRate = $0 / 100 }), format: .number)
                }
                Picker("Devise", selection: $inv.currency) { ForEach(["EUR", "CAD", "USD", "CHF", "GBP"], id: \.self) { Text($0).tag($0) } }
            }
            Section {
                ForEach($inv.lines) { $line in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        TextField("Désignation", text: $line.description, axis: .vertical).lineLimit(1...3)
                        TextField("Qté", value: $line.quantity, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 60).multilineTextAlignment(.trailing)
                        TextField("", text: $line.unit).frame(width: 34)
                        TextField("P.U.", value: $line.unitPrice, format: .number.precision(.fractionLength(0...2)))
                            .frame(width: 80).multilineTextAlignment(.trailing)
                        Text(Billing.money(line.total, inv.currency)).monospacedDigit().frame(width: 100, alignment: .trailing)
                        Button { inv.lines.removeAll { $0.id == line.id } } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.plain)
                    }
                    .labelsHidden()
                }
                .onMove { inv.lines.move(fromOffsets: $0, toOffset: $1) }
                Button {
                    inv.lines.append(InvoiceLine(description: "", quantity: 1, unit: "h",
                                                 unitPrice: store.client(inv.clientId).map(store.rate(for:)) ?? Billing.defaultRate))
                } label: { Label("Ajouter une ligne", systemImage: "plus") }
            } header: {
                Text("Lignes (\(Billing.number(inv.hours)) h)")
            }
            Section("Totaux") {
                LabeledContent("Total HT", value: Billing.money(inv.subtotal, inv.currency))
                if inv.vatMode.appliesVAT { LabeledContent("TVA", value: Billing.money(inv.vat, inv.currency)) }
                LabeledContent(inv.vatMode.appliesVAT ? "Total TTC" : "Total") {
                    Text(Billing.money(inv.total, inv.currency)).font(.headline)
                }
                if let m = inv.vatMode.mention { Text(m).font(.caption).foregroundStyle(.secondary) }
            }
            Section("Note sur la facture") {
                TextField("Ex. bon de commande, référence…", text: $inv.notes, axis: .vertical).lineLimit(2...4)
            }
            if !inv.entryIds.isEmpty {
                Section("Temps inclus") {
                    Text("\(inv.entryIds.count) entrées de temps · marquées « facturé »").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = Billing.invoicesFolder
        panel.nameFieldStringValue = "\(inv.number) – \(store.client(inv.clientId)?.name ?? "client").pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportInvoicePDF(inv, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            if inv.status == .draft { inv.status = .sent }
        } catch {
            store.showToast((error as? APIError)?.message ?? error.localizedDescription)
        }
    }
}

// MARK: - Clients

struct ClientsView: View {
    @EnvironmentObject var store: Store
    @State private var newName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle.badge.plus").foregroundStyle(Color.accentColor).font(.title3)
                    TextField("Nouveau client… (Entrée)", text: $newName).textFieldStyle(.plain).font(.title3)
                        .onSubmit {
                            let n = newName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            store.upsertClient(Client(name: n))
                            newName = ""
                        }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14)], spacing: 14) {
                    ForEach(store.clients.filter(store.clientInFacets)) { c in ClientCard(client: c) }
                }
            }
            .padding(24)
        }
        .navigationTitle("Clients")
    }
}

struct ClientCard: View {
    @EnvironmentObject var store: Store
    let client: Client

    private func bind<T>(_ kp: WritableKeyPath<Client, T>) -> Binding<T> {
        Binding(get: { store.client(client.id)?[keyPath: kp] ?? client[keyPath: kp] },
                set: { var c = store.client(client.id) ?? client; c[keyPath: kp] = $0; store.upsertClient(c) })
    }

    var body: some View {
        let billable = store.entries.filter { e in e.invoiceId == nil && e.end != nil && store.projects(of: client.id).contains { $0.id == e.projectId } }
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Avatar(name: client.name)
                    TextField("Nom", text: bind(\.name)).textFieldStyle(.plain).font(.headline)
                    Spacer()
                    Menu {
                        Button("Supprimer", role: .destructive) { store.deleteClient(client.id) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
                TextField("Adresse", text: bind(\.address), axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("E-mail", text: bind(\.email)).textFieldStyle(.roundedBorder)
                    TextField("N° TVA", text: bind(\.vatNumber)).textFieldStyle(.roundedBorder)
                }
                HStack {
                    TextField("SIRET", text: bind(\.siret)).textFieldStyle(.roundedBorder)
                    TextField("Taux horaire", value: bind(\.rate), format: .number).textFieldStyle(.roundedBorder).frame(width: 110)
                    Picker("", selection: bind(\.currency)) { ForEach(["EUR", "CAD", "USD", "CHF", "GBP"], id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: 80)
                }
                Picker("TVA", selection: bind(\.vatMode)) { ForEach(VatMode.allCases) { Text($0.label).tag($0) } }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Projets facturés à ce client").font(.caption).foregroundStyle(.secondary)
                    FlowLayout(spacing: 6) {
                        ForEach(store.projects.filter { !$0.archived || $0.clientId == client.id }) { p in
                            let on = p.clientId == client.id
                            Button {
                                var x = p; x.clientId = on ? nil : client.id; store.upsertProject(x)
                            } label: {
                                HStack(spacing: 4) {
                                    Circle().fill(Color(hex: p.color)).frame(width: 7, height: 7)
                                    Text(p.name)
                                    if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)) }
                                }
                                .font(.callout)
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Capsule().fill(on ? Color(hex: p.color).opacity(0.2) : Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                HStack {
                    Label("\(Billing.number(billable.reduce(0) { $0 + $1.duration } / 3600)) h non facturées", systemImage: "clock")
                    Spacer()
                    Text("\(store.invoices.filter { $0.clientId == client.id }.count) factures")
                }
                .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
