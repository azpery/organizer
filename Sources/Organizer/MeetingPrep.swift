import Foundation

/// Builds a preparation note for a calendar event with the local model, from related notes, tasks and mails.
extension Store {
    private static let stopwords: Set<String> = [
        "avec", "pour", "dans", "chez", "sur", "les", "des", "une", "aux", "par", "point", "réunion", "reunion", "meeting",
        "call", "appel", "visio", "suite", "faire", "this", "that", "from", "with", "the", "and", "entre", "point", "hebdo",
    ]

    static func keywords(_ text: String) -> Set<String> {
        let folded = text.lowercased().folding(options: .diacriticInsensitive, locale: Locale(identifier: "fr_FR"))
        let words = folded.components(separatedBy: CharacterSet.alphanumerics.inverted)
        return Set(words.filter { $0.count >= 4 && !stopwords.contains($0) && Int($0) == nil })
    }

    func prepKey(_ e: CalendarEvent) -> String { "gcal:\(e.id):\(Fmt.isoDay(e.start))" }

    func prepNote(for e: CalendarEvent) -> Note? { notes.first { $0.externalId == prepKey(e) } }

    struct MeetingContext {
        var notes: [Note]
        var tasks: [TaskItem]
        var mails: [MailSnippet]
        var facets: [String]
    }

    func context(for e: CalendarEvent) async -> MeetingContext {
        let kw = Self.keywords(e.title + " " + (e.details ?? "") + " " + e.attendees.joined(separator: " "))
        func score(_ text: String) -> Int { Self.keywords(text).intersection(kw).count }

        var scoredNotes: [(Note, Int)] = []
        for n in notes where !(n.externalId?.hasPrefix("gcal:") ?? false) {
            let sc: Int = score(n.title) * 3 + score(n.body)
            if sc >= 2 { scoredNotes.append((n, sc)) }
        }
        scoredNotes.sort { a, b in a.1 != b.1 ? a.1 > b.1 : a.0.updatedAt > b.0.updatedAt }
        let relNotes: [Note] = scoredNotes.prefix(5).map { $0.0 }

        let monthAgo = Date().addingTimeInterval(-30 * 86400)
        var scoredTasks: [(TaskItem, Int)] = []
        for t in tasks where t.status != .done || (t.completedAt ?? .distantPast) > monthAgo {
            let sc: Int = score(t.title) * 3 + score(t.notes) + score(t.labels.joined(separator: " "))
            if sc >= 2 { scoredTasks.append((t, sc)) }
        }
        scoredTasks.sort { $0.1 > $1.1 }
        let relTasks: [TaskItem] = scoredTasks.prefix(8).map { $0.0 }
        let mails = (try? await MailSource.search(keywords: kw, attendees: e.attendees, limit: 6)) ?? []

        var facetCount: [String: Int] = [:]
        for n in relNotes { for l in n.labels { facetCount[l, default: 0] += 1 } }
        for t in relTasks { for l in t.labels where l != Facets.waiting { facetCount[l, default: 0] += 1 } }
        let facets = facetCount.sorted { $0.value > $1.value }.prefix(2).map(\.key)
        return MeetingContext(notes: Array(relNotes), tasks: Array(relTasks), mails: mails, facets: facets)
    }

    @discardableResult
    func prepareMeeting(_ e: CalendarEvent) async throws -> Note {
        let ctx = await context(for: e)
        var parts: [String] = []
        parts.append("Réunion : \(e.title)")
        parts.append("Quand : \(Fmt.longDay(e.start)) de \(Fmt.time(e.start)) à \(Fmt.time(e.end))")
        if !e.attendees.isEmpty { parts.append("Participants : \(e.attendees.joined(separator: ", "))") }
        if let d = e.details, !d.isEmpty { parts.append("Description de l'invitation :\n\(d.prefix(1500))") }
        if !ctx.tasks.isEmpty {
            parts.append("Tâches et tickets liés :\n" + ctx.tasks.map { t in
                var s = "- \(t.jiraKey.map { "\($0) " } ?? "")\(t.title) [\(t.status.label)]"
                if let d = t.dueDate { s += " échéance \(Fmt.date(d))" }
                if let mr = mergeRequests[t.id]?.first { s += " · MR !\(mr.iid) \(mr.label)" }
                let n = t.notes.replacingOccurrences(of: "\n", with: " ").prefix(400)
                if !n.isEmpty { s += "\n  suivi : \(n)" }
                return s
            }.joined(separator: "\n"))
        }
        if !ctx.notes.isEmpty {
            parts.append("Notes existantes :\n" + ctx.notes.map { "### \($0.title) (\(Fmt.date($0.updatedAt)))\n\($0.body.prefix(900))" }.joined(separator: "\n"))
        }
        if !ctx.mails.isEmpty {
            parts.append("Mails récents :\n" + ctx.mails.map { "- \(Fmt.date($0.date)) de \($0.from) : « \($0.subject) »\n  \($0.excerpt.prefix(500))" }.joined(separator: "\n"))
        }

        let system = """
        Tu prépares \(Profile.who) à une réunion. Réponds en français, en Markdown, de façon concise et concrète. \
        Appuie-toi uniquement sur le contexte fourni ; si une information manque, dis-le plutôt que d'inventer.
        Structure exacte :
        ## De quoi il s'agit
        (2-4 puces : sujet, enjeux, historique utile)
        ## Où on en est
        (puces avec l'état des tickets/tâches cités, clés de ticket comprises)
        ## Ce que tu peux dire
        (3-5 puces formulées à la première personne, prêtes à être dites)
        ## Questions à poser
        (2-4 puces)
        ## Points de vigilance
        (1-3 puces, ou « Rien de particulier »)
        """
        let content = try await Ollama.chat(system: system, user: parts.joined(separator: "\n\n"))
        var sources: [String] = []
        sources += ctx.tasks.prefix(5).map { "- Tâche : \($0.jiraKey.map { "\($0) · " } ?? "")\($0.title)" }
        sources += ctx.notes.map { "- Note : \($0.title)" }
        sources += ctx.mails.map { "- Mail : \($0.subject) (\($0.from))" }
        let body = content + (sources.isEmpty ? "" : "\n\n---\n**Sources utilisées**\n" + sources.joined(separator: "\n"))
            + "\n\n_Préparé par \(Ollama.model) le \(Fmt.date(Date())) à \(Fmt.time(Date()))_"

        var note = prepNote(for: e) ?? Note(title: "Préparation · \(e.title) · \(Fmt.date(e.start))")
        note.body = body
        note.labels = ctx.facets
        note.taskId = ctx.tasks.first(where: { $0.jiraKey != nil })?.id ?? ctx.tasks.first?.id
        note.externalId = prepKey(e)
        note.pinned = true
        return upsertNote(note)
    }

    /// Prepares meetings starting within the next hour that have no prep note yet.
    func autoPrepareMeetings() async {
        guard UserDefaults.standard.object(forKey: "autoPrep") as? Bool ?? true, !preparing else { return }
        let soon = todayEvents.filter { !$0.allDay && $0.start > Date() && $0.start < Date().addingTimeInterval(3600) && prepNote(for: $0) == nil }
        guard let next = soon.first else { return }
        preparing = true
        defer { preparing = false }
        if (try? await prepareMeeting(next)) != nil {
            showToast("✓ Prépa prête pour « \(next.title) » à \(Fmt.time(next.start))")
        }
    }
}

/// Mail snippet used as context (provided by MailSource).
struct MailSnippet: Identifiable, Hashable {
    let id: String
    let subject: String
    let from: String
    let date: Date
    let excerpt: String
    var account: String = ""
    var read: Bool = true
}
