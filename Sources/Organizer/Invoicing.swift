import Foundation
import SwiftUI
import AppKit

/// Seller details and invoicing defaults (Réglages › Facturation).
enum Billing {
    private static var d: UserDefaults { .standard }
    static var sellerName: String { d.string(forKey: "billing.name") ?? "" }
    static var sellerAddress: String { d.string(forKey: "billing.address") ?? "" }
    static var siret: String { d.string(forKey: "billing.siret") ?? "" }
    static var vatNumber: String { d.string(forKey: "billing.vat") ?? "" }
    static var email: String { d.string(forKey: "billing.email") ?? "" }
    static var phone: String { d.string(forKey: "billing.phone") ?? "" }
    static var iban: String { d.string(forKey: "billing.iban") ?? "" }
    static var bic: String { d.string(forKey: "billing.bic") ?? "" }
    static var defaultRate: Double { d.object(forKey: "billing.rate") as? Double ?? 0 }
    static var paymentDays: Int { d.object(forKey: "billing.paymentDays") as? Int ?? 30 }
    static var prefix: String { (d.string(forKey: "billing.prefix") ?? "F").trimmingCharacters(in: .whitespaces) }
    /// Number template: {YYYY} / {YY} for the year, {SEQ3}…{SEQ6} for the yearly counter. Ex. "F{YY}{SEQ5}" → F2600006.
    static var numberTemplate: String {
        let t = (d.string(forKey: "billing.template") ?? "").trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "\(prefix)-{YYYY}-{SEQ3}" : t
    }
    static var nextSeqOverride: Int { d.integer(forKey: "billing.nextSeq") }
    static var extraMentions: String { d.string(forKey: "billing.mentions") ?? "" }
    static var roundingMinutes: Int { d.object(forKey: "billing.rounding") as? Int ?? 15 }

    static var invoicesFolder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Factures", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func money(_ v: Double, _ currency: String) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "fr_FR")
        f.currencyCode = currency
        // the narrow no-break space used by fr_FR is not drawn by the PDF font: use a regular no-break space
        return (f.string(from: NSNumber(value: v)) ?? String(format: "%.2f %@", v, currency))
            .replacingOccurrences(of: "\u{202F}", with: "\u{00A0}")
    }

    static func number(_ v: Double, digits: Int = 2) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }
}

enum InvoiceGrouping: String, CaseIterable, Identifiable {
    case task, project, day
    var id: String { rawValue }
    var label: String { switch self { case .task: "Par tâche"; case .project: "Par projet"; case .day: "Par jour" } }
}

extension Store {
    // MARK: Clients

    func client(_ id: String?) -> Client? {
        guard let id else { return nil }
        return clients.first { $0.id == id }
    }

    @discardableResult
    func upsertClient(_ c: Client) -> Client {
        do { try db.saveJSON("clients", c) } catch { lastError = "\(error)" }
        if let i = clients.firstIndex(where: { $0.id == c.id }) { clients[i] = c } else { clients.append(c) }
        clients.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return c
    }

    func deleteClient(_ id: String) {
        try? db.delete(table: "clients", id: id)
        clients.removeAll { $0.id == id }
        for var p in projects where p.clientId == id { p.clientId = nil; upsertProject(p) }
    }

    func projects(of clientId: String) -> [Project] { projects.filter { $0.clientId == clientId } }

    func clientInFacets(_ c: Client) -> Bool {
        activeFacets.isEmpty || projects(of: c.id).contains { projectInFacets($0) }
    }

    func rate(for c: Client) -> Double { c.rate > 0 ? c.rate : Billing.defaultRate }

    // MARK: Invoices

    func invoice(_ id: String?) -> Invoice? {
        guard let id else { return nil }
        return invoices.first { $0.id == id }
    }

    @discardableResult
    func upsertInvoice(_ inv: Invoice) -> Invoice {
        do { try db.saveJSON("invoices", inv, extra: ["number": inv.number]) } catch { lastError = "\(error)" }
        if let i = invoices.firstIndex(where: { $0.id == inv.id }) { invoices[i] = inv } else { invoices.append(inv) }
        invoices.sort { ($0.issueDate, $0.number) > ($1.issueDate, $1.number) }
        // Reserve the included time entries for this invoice.
        let ids = Set(inv.entryIds)
        for var e in entries where (ids.contains(e.id) && e.invoiceId != inv.id) || (!ids.contains(e.id) && e.invoiceId == inv.id) {
            e.invoiceId = ids.contains(e.id) ? inv.id : nil
            upsertEntry(e)
        }
        return inv
    }

    func deleteInvoice(_ id: String) {
        try? db.delete(table: "invoices", id: id)
        invoices.removeAll { $0.id == id }
        for var e in entries where e.invoiceId == id { e.invoiceId = nil; upsertEntry(e) }
    }

    func nextInvoiceNumber(for date: Date = Date()) -> String {
        let year = Calendar.app.component(.year, from: date)
        var template = Billing.numberTemplate
            .replacingOccurrences(of: "{YYYY}", with: String(year))
            .replacingOccurrences(of: "{YY}", with: String(format: "%02d", year % 100))
        var width = 3
        for w in 1...8 where template.contains("{SEQ\(w)}") { width = w; template = template.replacingOccurrences(of: "{SEQ\(w)}", with: "{SEQ}") }
        let parts = template.components(separatedBy: "{SEQ}")
        let head = parts.first ?? "", tail = parts.count > 1 ? parts[1] : ""
        let used = invoices.compactMap { inv -> Int? in
            guard inv.number.hasPrefix(head), inv.number.hasSuffix(tail), inv.number.count == head.count + width + tail.count else { return nil }
            return Int(inv.number.dropFirst(head.count).dropLast(tail.count))
        }
        let next = max((used.max() ?? 0) + 1, Billing.nextSeqOverride)
        return head + String(format: "%0\(width)d", next) + tail
    }

    /// Uninvoiced, finished entries of the client's projects in [from, to).
    func billableEntries(clientId: String, from: Date, to: Date) -> [TimeEntry] {
        let projectIds = Set(projects(of: clientId).map(\.id))
        return entries.filter { e in
            guard let pid = e.projectId, projectIds.contains(pid), e.end != nil, e.invoiceId == nil else { return false }
            return e.start >= from && e.start < to
        }
        .sorted { $0.start < $1.start }
    }

    /// Builds a draft invoice from the time spent for a client over a period.
    func buildInvoice(clientId: String, from: Date, to: Date, grouping: InvoiceGrouping = .task) throws -> Invoice {
        guard let c = client(clientId) else { throw APIError(404, "Client introuvable") }
        let list = billableEntries(clientId: clientId, from: from, to: to)
        guard !list.isEmpty else { throw APIError(400, "Aucun temps non facturé pour \(c.name) sur cette période") }
        let rate = rate(for: c)
        let step = Double(max(1, Billing.roundingMinutes)) / 60

        var order: [String] = []
        var groups: [String: (label: String, seconds: TimeInterval, count: Int)] = [:]
        for e in list {
            let key: String
            let label: String
            switch grouping {
            case .task:
                if let t = task(e.taskId) {
                    key = "t:" + t.id
                    label = t.jiraKey.map { "\($0) · \(t.title)" } ?? t.title
                } else {
                    let d = e.description.isEmpty ? (project(e.projectId)?.name ?? "Prestations") : e.description
                    key = "d:" + d.lowercased()
                    label = d
                }
            case .project:
                key = "p:" + (e.projectId ?? "")
                label = "Prestations — " + (project(e.projectId)?.name ?? "Divers")
            case .day:
                let day = Calendar.app.startOfDay(for: e.start)
                key = "j:\(day.timeIntervalSince1970)"
                label = Fmt.longDay(day)
            }
            if groups[key] == nil { order.append(key); groups[key] = (label, 0, 0) }
            groups[key]!.seconds += e.duration
            groups[key]!.count += 1
        }
        let lines = order.map { k -> InvoiceLine in
            let g = groups[k]!
            let hours = max(step, ((g.seconds / 3600) / step).rounded(.up) * step)
            return InvoiceLine(description: g.label, quantity: hours, unit: "h", unitPrice: rate)
        }
        let issue = Date()
        var inv = Invoice(number: nextInvoiceNumber(for: issue), clientId: c.id)
        inv.issueDate = issue
        inv.dueDate = Calendar.app.date(byAdding: .day, value: Billing.paymentDays, to: issue)!
        inv.periodStart = from
        inv.periodEnd = Calendar.app.date(byAdding: .day, value: -1, to: to)
        inv.lines = lines
        inv.vatMode = c.vatMode
        inv.currency = c.currency
        inv.entryIds = list.map(\.id)
        return inv
    }

    // MARK: PDF

    /// Renders the invoice to an A4 PDF (paginated) and returns its URL.
    @discardableResult
    func exportInvoicePDF(_ inv: Invoice, to url: URL? = nil) throws -> URL {
        let dest = url ?? Billing.invoicesFolder.appendingPathComponent("\(inv.number) – \(client(inv.clientId)?.name ?? "client").pdf")
        let pages = InvoiceDocument.paginate(inv)
        var box = CGRect(x: 0, y: 0, width: InvoiceDocument.pageSize.width, height: InvoiceDocument.pageSize.height)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &box, nil) else { throw APIError(500, "Impossible de créer le PDF") }
        for (i, slice) in pages.enumerated() {
            let page = InvoiceDocument(invoice: inv, client: client(inv.clientId), lines: slice, pageIndex: i, pageCount: pages.count)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(InvoiceDocument.pageSize)
            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return dest
    }
}

/// A4 invoice page (also used as on-screen preview).
struct InvoiceDocument: View {
    static let pageSize = CGSize(width: 595, height: 842)
    static let firstPageLines = 14
    static let otherPageLines = 24

    let invoice: Invoice
    let client: Client?
    var lines: [InvoiceLine]? = nil
    var pageIndex = 0
    var pageCount = 1

    static func paginate(_ inv: Invoice) -> [[InvoiceLine]] {
        var pages: [[InvoiceLine]] = [Array(inv.lines.prefix(firstPageLines))]
        var rest = Array(inv.lines.dropFirst(firstPageLines))
        while !rest.isEmpty {
            pages.append(Array(rest.prefix(otherPageLines)))
            rest = Array(rest.dropFirst(otherPageLines))
        }
        return pages
    }

    private let ink = Color(white: 0.12)
    private let muted = Color(white: 0.45)
    private let accent = Color(hex: "#4F7CFF")
    private var isLast: Bool { pageIndex == pageCount - 1 }

    var body: some View {
        let shown = lines ?? invoice.lines
        VStack(alignment: .leading, spacing: 0) {
            if pageIndex == 0 { header } else {
                HStack {
                    Text("Facture \(invoice.number)").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("Page \(pageIndex + 1) / \(pageCount)").font(.system(size: 9)).foregroundStyle(muted)
                }
                .padding(.bottom, 16)
            }
            table(shown)
            if isLast {
                totals.padding(.top, 14)
                Spacer(minLength: 16)
                footer
            } else {
                Spacer()
                Text("Suite page suivante…").font(.system(size: 9)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(42)
        .frame(width: Self.pageSize.width, height: Self.pageSize.height, alignment: .topLeading)
        .background(Color.white)
        .foregroundStyle(ink)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(Billing.sellerName.isEmpty ? "Votre entreprise" : Billing.sellerName).font(.system(size: 15, weight: .bold))
                    if !Billing.sellerAddress.isEmpty { Text(Billing.sellerAddress).font(.system(size: 9)).foregroundStyle(muted) }
                    Group {
                        if !Billing.siret.isEmpty { Text("SIRET \(Billing.siret)") }
                        if !Billing.vatNumber.isEmpty { Text("TVA intracommunautaire \(Billing.vatNumber)") }
                        if !Billing.email.isEmpty { Text(Billing.email) }
                        if !Billing.phone.isEmpty { Text(Billing.phone) }
                    }
                    .font(.system(size: 9)).foregroundStyle(muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("FACTURE").font(.system(size: 20, weight: .bold)).kerning(2)
                    Text("N° \(invoice.number)").font(.system(size: 11, weight: .semibold))
                    Text("Date : \(Fmt.date(invoice.issueDate))").font(.system(size: 9))
                    Text("Échéance : \(Fmt.date(invoice.dueDate))").font(.system(size: 9))
                }
            }
            HStack(alignment: .top) {
                if let s = invoice.periodStart, let e = invoice.periodEnd {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("PÉRIODE").font(.system(size: 8, weight: .bold)).foregroundStyle(muted).kerning(1)
                        Text("Du \(Fmt.date(s)) au \(Fmt.date(e))").font(.system(size: 10))
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 3) {
                    Text("FACTURÉ À").font(.system(size: 8, weight: .bold)).foregroundStyle(muted).kerning(1)
                    Text(client?.name ?? "Client").font(.system(size: 12, weight: .semibold))
                    if let a = client?.address, !a.isEmpty { Text(a).font(.system(size: 9)) }
                    if let v = client?.vatNumber, !v.isEmpty { Text("TVA \(v)").font(.system(size: 9)).foregroundStyle(muted) }
                    if let s = client?.siret, !s.isEmpty { Text("SIRET \(s)").font(.system(size: 9)).foregroundStyle(muted) }
                }
                .padding(12)
                .frame(width: 230, alignment: .leading)
                .overlay(Rectangle().stroke(Color(white: 0.82), lineWidth: 0.5))
            }
        }
        .padding(.bottom, 22)
    }

    private func table(_ shown: [InvoiceLine]) -> some View {
        let rule = Color(white: 0.82)
        return VStack(spacing: 0) {
            HStack {
                Text("Désignation").frame(maxWidth: .infinity, alignment: .leading)
                Text("Qté").frame(width: 50, alignment: .trailing)
                Text("P.U. HT").frame(width: 70, alignment: .trailing)
                Text("Total HT").frame(width: 80, alignment: .trailing)
            }
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(muted)
            .padding(.vertical, 6)
            Rectangle().fill(ink).frame(height: 0.8)
            ForEach(shown) { l in
                HStack(alignment: .top) {
                    Text(l.description).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                    Text("\(Billing.number(l.quantity)) \(l.unit)").frame(width: 50, alignment: .trailing)
                    Text(Billing.money(l.unitPrice, invoice.currency)).frame(width: 70, alignment: .trailing)
                    Text(Billing.money(l.total, invoice.currency)).frame(width: 80, alignment: .trailing)
                }
                .font(.system(size: 9.5))
                .padding(.vertical, 6)
                Rectangle().fill(rule).frame(height: 0.75)
            }
            if isLast {
                HStack {
                    Text("Total heures").fontWeight(.semibold).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(Billing.number(invoice.hours)) h").fontWeight(.semibold).frame(width: 50, alignment: .trailing)
                    Spacer().frame(width: 150)
                }
                .font(.system(size: 9.5))
                .padding(.vertical, 6)
            }
        }
    }

    private var totals: some View {
        HStack {
            Spacer()
            VStack(spacing: 5) {
                row("Total HT", Billing.money(invoice.subtotal, invoice.currency))
                if invoice.vatMode.appliesVAT {
                    row("TVA \(Billing.number(invoice.vatRate * 100)) %", Billing.money(invoice.vat, invoice.currency))
                }
                Divider()
                row(invoice.vatMode.appliesVAT ? "Total TTC" : "Total", Billing.money(invoice.total, invoice.currency), bold: true)
            }
            .frame(width: 220)
        }
    }

    private func row(_ l: String, _ v: String, bold: Bool = false) -> some View {
        HStack {
            Text(l)
            Spacer()
            Text(v)
        }
        .font(.system(size: bold ? 12 : 10, weight: bold ? .bold : .regular))
        .foregroundStyle(ink)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let m = invoice.vatMode.mention { Text(m).font(.system(size: 9, weight: .semibold)) }
            if !invoice.notes.isEmpty { Text(invoice.notes).font(.system(size: 9)) }
            if !Billing.iban.isEmpty {
                Text("Règlement par virement — IBAN \(Billing.iban)\(Billing.bic.isEmpty ? "" : " — BIC \(Billing.bic)")")
                    .font(.system(size: 9))
            }
            Text("Paiement à \(Billing.paymentDays) jours, au plus tard le \(Fmt.date(invoice.dueDate)). Pas d'escompte pour paiement anticipé. En cas de retard, pénalités au taux de trois fois le taux d'intérêt légal et indemnité forfaitaire pour frais de recouvrement de 40 € (art. L441-10 du Code de commerce).")
                .font(.system(size: 7.5)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
            if !Billing.extraMentions.isEmpty {
                Text(Billing.extraMentions).font(.system(size: 7.5)).foregroundStyle(muted)
            }
            if pageCount > 1 {
                Text("Page \(pageIndex + 1) / \(pageCount)").font(.system(size: 8)).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
