import Foundation
import SwiftUI

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case backlog, todo, in_progress, almost_done, done

    var id: String { rawValue }

    var label: String {
        switch self {
        case .backlog: "Backlog"
        case .todo: "À faire"
        case .in_progress: "En cours"
        case .almost_done: "Presque terminé"
        case .done: "Terminée"
        }
    }

    var icon: String {
        switch self {
        case .backlog: "tray.full"
        case .todo: "circle"
        case .in_progress: "circle.lefthalf.filled"
        case .almost_done: "circle.dotted.circle"
        case .done: "checkmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .backlog: .gray
        case .todo: .blue
        case .in_progress: .orange
        case .almost_done: .purple
        case .done: .green
        }
    }

    /// Tolerant parsing for API input ("in-progress", "en cours", "doing"...).
    static func parse(_ raw: String) -> TaskStatus? {
        let s = raw.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        switch s {
        case "backlog": return .backlog
        case "todo", "to_do", "a_faire": return .todo
        case "in_progress", "inprogress", "doing", "en_cours", "wip": return .in_progress
        case "almost_done", "almostdone", "presque_termine", "presque_terminee", "review", "en_revue", "revue", "revue_en_cours": return .almost_done
        case "done", "terminee", "termine", "finished", "closed": return .done
        default: return nil
        }
    }
}

enum WorkContext: String, Codable, CaseIterable, Identifiable {
    case pro, perso
    var id: String { rawValue }
    var label: String { self == .pro ? "Pro" : "Perso" }
    var icon: String { self == .pro ? "briefcase.fill" : "house.fill" }
}

struct Project: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var color: String = Palette.next()
    var client: String? = nil
    var context: WorkContext = .pro
    var archived: Bool = false
    var clockifyId: String? = nil
    var labels: [String] = []
    /// Billing client (Clients view).
    var clientId: String? = nil
}

struct TaskItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var notes: String = ""
    var projectId: String? = nil
    var status: TaskStatus = .backlog
    var context: WorkContext = .pro
    /// 0 = aucune, 1 = basse, 2 = moyenne, 3 = haute
    var priority: Int = 0
    /// Facettes (ex. "Refonte site", "Maintenance", "Perso")
    var labels: [String] = []
    var position: Double = Date().timeIntervalSince1970
    var jiraKey: String? = nil
    var url: String? = nil
    var dueDate: Date? = nil
    var estimateMinutes: Int? = nil
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var completedAt: Date? = nil
    var clockifyId: String? = nil
}

struct TimeEntry: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var description: String = ""
    var projectId: String? = nil
    var taskId: String? = nil
    var start: Date
    var end: Date? = nil
    var tags: [String] = []
    var billable: Bool = false
    var clockifyId: String? = nil
    /// Set once the entry is included in an invoice (prevents double billing).
    var invoiceId: String? = nil

    var isRunning: Bool { end == nil }
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }

    static func newManual() -> TimeEntry {
        let cal = Calendar.app
        let now = Date()
        let end = cal.date(bySetting: .second, value: 0, of: now) ?? now
        return TimeEntry(start: end.addingTimeInterval(-3600), end: end)
    }
}

struct Note: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var body: String = ""
    var labels: [String] = []
    var taskId: String? = nil
    var pinned: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    /// Apple Notes identifier when the note is linked to Notes.app (content is then read-only here),
    /// or "gcal:<event>:<day>" for meeting preparations.
    var externalId: String? = nil

    var isAppleNote: Bool { externalId.map { !$0.hasPrefix("gcal:") } ?? false }
}

// MARK: - Invoicing

enum VatMode: String, Codable, CaseIterable, Identifiable {
    case standard, outsideEU, reverseChargeEU, franchise
    var id: String { rawValue }

    var label: String {
        switch self {
        case .standard: "TVA française"
        case .outsideEU: "Client hors UE (sans TVA)"
        case .reverseChargeEU: "Client UE (autoliquidation)"
        case .franchise: "Franchise en base"
        }
    }

    var appliesVAT: Bool { self == .standard }

    var mention: String? {
        switch self {
        case .standard: nil
        case .outsideEU: "TVA non applicable, art. 259-1 du CGI"
        case .reverseChargeEU: "Autoliquidation par le preneur, art. 283-2 du CGI"
        case .franchise: "TVA non applicable, art. 293 B du CGI"
        }
    }
}

struct Client: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var address: String = ""
    var email: String = ""
    var vatNumber: String = ""
    var siret: String = ""
    /// Hourly rate; 0 = default rate from settings.
    var rate: Double = 0
    var currency: String = "EUR"
    var vatMode: VatMode = .standard
    var notes: String = ""
}

enum InvoiceStatus: String, Codable, CaseIterable, Identifiable {
    case draft, sent, paid
    var id: String { rawValue }
    var label: String { switch self { case .draft: "Brouillon"; case .sent: "Émise"; case .paid: "Payée" } }
    var color: Color { switch self { case .draft: .gray; case .sent: .blue; case .paid: .green } }
    var icon: String { switch self { case .draft: "pencil.circle"; case .sent: "paperplane.fill"; case .paid: "checkmark.seal.fill" } }
}

struct InvoiceLine: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var description: String
    var quantity: Double
    var unit: String = "h"
    var unitPrice: Double
    var total: Double { (quantity * unitPrice * 100).rounded() / 100 }
}

struct Invoice: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var number: String
    var clientId: String
    var issueDate: Date = Date()
    var dueDate: Date = Calendar.app.date(byAdding: .day, value: 30, to: Date())!
    var periodStart: Date? = nil
    var periodEnd: Date? = nil
    var lines: [InvoiceLine] = []
    var vatRate: Double = 0.2
    var vatMode: VatMode = .standard
    var currency: String = "EUR"
    var status: InvoiceStatus = .draft
    var notes: String = ""
    var entryIds: [String] = []
    var createdAt: Date = Date()

    var subtotal: Double { lines.reduce(0) { $0 + $1.total } }
    var vat: Double { vatMode.appliesVAT ? (subtotal * vatRate * 100).rounded() / 100 : 0 }
    var total: Double { subtotal + vat }
    var hours: Double { lines.filter { $0.unit == "h" }.reduce(0) { $0 + $1.quantity } }
}

enum Facets {
    /// Transversal facet for tickets waiting on the client side.
    static var waiting: String {
        let v = (UserDefaults.standard.string(forKey: "waitingFacet") ?? "").trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? "⏳ En attente" : v
    }
}

/// Who the user is, as told to the local assistant (Réglages › Profil). Nothing personal lives in the code.
enum Profile {
    static var firstName: String? {
        let own = (UserDefaults.standard.string(forKey: "profile.name") ?? "").trimmingCharacters(in: .whitespaces)
        if !own.isEmpty { return own }
        let billing = UserDefaults.standard.string(forKey: "billing.name")?.components(separatedBy: " ").first ?? ""
        return billing.isEmpty ? nil : billing
    }
    /// Free text, e.g. "développeur freelance ; clients : A, B".
    static var about: String { (UserDefaults.standard.string(forKey: "profile.about") ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    static var name: String { firstName ?? "l'utilisateur" }
    /// "Camille (développeuse freelance…)" or "l'utilisateur".
    static var who: String { about.isEmpty ? name : "\(name) (\(about))" }
}

enum ArtifactKind: String, Codable, CaseIterable, Identifiable {
    case artifact, document, design, code, link, file
    var id: String { rawValue }

    var label: String {
        switch self {
        case .artifact: "Artifact Claude"
        case .document: "Document"
        case .design: "Design"
        case .code: "Code"
        case .link: "Lien"
        case .file: "Fichier"
        }
    }

    var icon: String {
        switch self {
        case .artifact: "sparkles"
        case .document: "doc.text.fill"
        case .design: "paintpalette.fill"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .file: "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .artifact: Color(hex: "#D97757")
        case .document: .blue
        case .design: .pink
        case .code: .teal
        case .link: .indigo
        case .file: .gray
        }
    }
}

struct ArtifactItem: Identifiable, Codable, Hashable {
    var id: String = UUID().uuidString
    var title: String
    var url: String
    var kind: ArtifactKind = .artifact
    var summary: String = ""
    var labels: [String] = []
    var taskId: String? = nil
    var createdAt: Date = Date()
}

enum Palette {
    static let colors = [
        "#4F7CFF", "#9B5CFF", "#FF5C8A", "#FF8A3D", "#F5B83D",
        "#2EC4A6", "#34B5E5", "#7A8CA3", "#E05CD6", "#5CC46B",
    ]
    static func next() -> String { colors.randomElement()! }
}
