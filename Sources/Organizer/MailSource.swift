import Foundation

/// Reads recent mails from Apple Mail (all configured accounts) through JXA, stored locally for Ollama.
@MainActor
enum MailSource {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "mailEnabled") as? Bool ?? true }
    static var accounts: [String] { UserDefaults.standard.stringArray(forKey: "mailAccounts") ?? [] }
    static var days: Int { max(3, UserDefaults.standard.object(forKey: "mailDays") as? Int ?? 21) }

    /// Batched JXA: one Apple Event per property per mailbox (fast), bodies only for the most recent mails.
    private static let fetchScript = """
    function run(argv) {
      const since = new Date(argv[0]);
      const wanted = JSON.parse(argv[1]);
      const bodySince = new Date(argv[2]);
      const Mail = Application('Mail');
      const out = [];
      const seen = {};
      for (const a of Mail.accounts()) {
        const name = a.name();
        if (seen[name]) continue;
        seen[name] = true;
        if (wanted.length && !wanted.includes(name)) continue;
        let mb = null;
        for (const n of ['INBOX', 'Inbox', 'Boîte de réception']) {
          try { const c = a.mailboxes.byName(n); c.name(); mb = c; break; } catch (e) {}
        }
        if (!mb) continue;
        try {
          const sel = mb.messages.whose({ dateReceived: { _greaterThan: since } });
          const ids = sel.messageId(), subj = sel.subject(), from = sel.sender(), dates = sel.dateReceived(), read = sel.readStatus();
          const bodies = {};
          try {
            const recent = mb.messages.whose({ dateReceived: { _greaterThan: bodySince } });
            const rids = recent.messageId(), rc = recent.content();
            for (let i = 0; i < rids.length; i++) bodies[rids[i]] = (rc[i] || '').slice(0, 2500);
          } catch (e) {}
          for (let i = 0; i < ids.length; i++) {
            out.push({ id: ids[i], account: name, subject: subj[i], from: from[i],
                       date: dates[i].toISOString(), read: read[i], excerpt: bodies[ids[i]] || '' });
          }
        } catch (e) {}
      }
      return JSON.stringify(out);
    }
    """

    private static let accountsScript = "function run() { return JSON.stringify(Application('Mail').accounts().map(a => a.name())); }"

    /// Running osascript, terminated when the app quits (otherwise it keeps Mail busy as an orphan).
    nonisolated(unsafe) static var running: Process?

    nonisolated static func terminateRunning() {
        if let p = running, p.isRunning { p.terminate() }
    }

    nonisolated private static func jxa(_ source: String, args: [String] = []) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-l", "JavaScript", "-e", source] + args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            try p.run()
            MailSource.running = p
            defer { MailSource.running = nil }
            // Never hang forever (e.g. a pending permission prompt): give up after 5 minutes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 300) { if p.isRunning { p.terminate() } }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationReason == .uncaughtSignal {
                throw APIError(504, "Apple Mail ne répond pas (délai dépassé). Vérifie l'autorisation dans Réglages Système › Confidentialité › Automatisation.")
            }
            guard p.terminationStatus == 0 else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                throw APIError(502, "Apple Mail : \(msg.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))")
            }
            return data
        }.value
    }

    static func listAccounts() async throws -> [String] {
        let data = try await jxa(accountsScript)
        let names = (try JSONSerialization.jsonObject(with: data) as? [String]) ?? []
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    static func fetch(since: Date) async throws -> [MailSnippet] {
        let iso = ISO8601DateFormatter()
        let accountsJSON = String(data: try JSONSerialization.data(withJSONObject: accounts), encoding: .utf8) ?? "[]"
        let bodySince = max(since, Date().addingTimeInterval(-3 * 86400))
        let data = try await jxa(fetchScript, args: [iso.string(from: since), accountsJSON, iso.string(from: bodySince)])
        let raw = (try JSONSerialization.jsonObject(with: data) as? [[String: Any]]) ?? []
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return raw.compactMap { m in
            guard let id = m["id"] as? String, let ds = m["date"] as? String,
                  let date = isoFrac.date(from: ds) ?? iso.date(from: ds) else { return nil }
            return MailSnippet(id: id, subject: m["subject"] as? String ?? "(sans objet)",
                               from: m["from"] as? String ?? "", date: date,
                               excerpt: clean(m["excerpt"] as? String ?? ""),
                               account: m["account"] as? String ?? "", read: m["read"] as? Bool ?? true)
        }
    }

    /// Drops quoted history and signatures noise, collapses whitespace.
    static func clean(_ text: String) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if (t.hasPrefix("Le ") && t.hasSuffix("a écrit :")) || (t.hasPrefix("On ") && t.hasSuffix("wrote:")) || t.hasPrefix("De : ") || t.hasPrefix("From: ") { break }
            if t == "--" { break }
            kept.append(t)
        }
        return kept.joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Local search over synced mails by keyword overlap and attendee addresses.
    static func search(keywords: Set<String>, attendees: [String], limit: Int) async throws -> [MailSnippet] {
        let people = Set(attendees.map { $0.lowercased() })
        var scored: [(MailSnippet, Int)] = []
        for m in Store.shared.mails where !Store.isAutomated(m) {
            let subjectHits: Int = Store.keywords(m.subject).intersection(keywords).count
            let bodyHits: Int = Store.keywords(m.excerpt).intersection(keywords).count
            let sender = m.from.lowercased()
            let fromMatch: Int = people.contains { sender.contains($0) } ? 4 : 0
            let total = subjectHits * 3 + bodyHits + fromMatch
            if total >= 3 { scored.append((m, total)) }
        }
        scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.date > $1.0.date }
        return scored.prefix(limit).map { $0.0 }
    }
}

extension Store {
    func syncMails() async {
        guard MailSource.enabled, !mailSyncing else { return }
        mailSyncing = true
        defer { mailSyncing = false }
        let windowStart = Calendar.app.date(byAdding: .day, value: -MailSource.days, to: Date())!
        let since = max(windowStart, (mails.map(\.date).max() ?? .distantPast).addingTimeInterval(-6 * 3600))
        do {
            let fetched = try await MailSource.fetch(since: since)
            let known = Dictionary(mails.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            try db.transaction {
                for var m in fetched {
                    if m.excerpt.isEmpty, let old = known[m.id], !old.excerpt.isEmpty {
                        m = MailSnippet(id: m.id, subject: m.subject, from: m.from, date: m.date, excerpt: old.excerpt, account: m.account, read: m.read)
                    }
                    try db.save(m)
                }
            }
            try db.run("DELETE FROM mails WHERE date < ?", [windowStart])
            mails = try db.loadMails()
            mailStatus = "✓ \(mails.count) mails · synchronisé à \(Fmt.time(Date()))"
        } catch {
            mailStatus = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    func startMailPolling() {
        Task { await syncMails() }
        Timer.scheduledTimer(withTimeInterval: 900, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncMails() }
        }
    }

    /// Automated senders (no-reply, notifications, newsletters, surveys) are noise for planning.
    static func isAutomated(_ m: MailSnippet) -> Bool {
        let from = m.from.lowercased()
        let subject = m.subject.lowercased()
        let senders = ["no-reply", "noreply", "do-not-reply", "donotreply", "notification", "newsletter", "mailer-daemon",
                       "support@", "info@", "news@", "marketing", "billing@", "@github.com", "@gitlab.com", "@atlassian.net"]
        let subjects = ["satisfaction", "votre avis", "your feedback", "newsletter", "webinar", "unsubscribe", "facture disponible", "receipt"]
        return senders.contains { from.contains($0) } || subjects.contains { subject.contains($0) }
    }

    /// Recent mails worth surfacing in the day plan (unread first, automated senders excluded).
    func recentMailsForPlan(limit: Int = 10) -> [MailSnippet] {
        let since = Date().addingTimeInterval(-36 * 3600)
        return mails.filter { $0.date > since && !Store.isAutomated($0) }
            .sorted { ($0.read ? 1 : 0, -$0.date.timeIntervalSince1970) < ($1.read ? 1 : 0, -$1.date.timeIntervalSince1970) }
            .prefix(limit).map { $0 }
    }
}
