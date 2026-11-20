import Foundation
import EventKit
import Network
import CryptoKit
import AppKit
import SwiftUI

// MARK: - OAuth (installed app, loopback redirect + PKCE)

/// Tiny one-shot HTTP listener on 127.0.0.1 to receive Google's OAuth redirect.
final class OAuthLoopback {
    private let listener: NWListener
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var pending: [String: String]?

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt16, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { [weak self] state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let e):
                    resumed = true
                    cont.resume(throwing: e)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .main)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
            guard let self, let data, let req = HTTPRequest.parse(data) else { conn.cancel(); return }
            let relevant = req.query["code"] != nil || req.query["error"] != nil
            let ok = req.query["code"] != nil
            let html = """
            <html><head><meta charset="utf-8"><title>Organizer</title></head>
            <body style="font-family:-apple-system;display:flex;height:90vh;align-items:center;justify-content:center;background:#111;color:#eee">
            <div style="text-align:center"><div style="font-size:48px">\(ok ? "✅" : "⚠️")</div>
            <h2>\(ok ? "Google Agenda est connecté à Organizer" : "Connexion annulée")</h2>
            <p style="color:#999">Tu peux fermer cet onglet.</p></div></body></html>
            """
            let body = Data(html.utf8)
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in conn.cancel() })
            if relevant { self.deliver(req.query) }
        }
    }

    private func deliver(_ query: [String: String]) {
        if let c = continuation { continuation = nil; c.resume(returning: query) } else { pending = query }
    }

    func waitForRedirect(timeout: TimeInterval = 300) async throws -> [String: String] {
        defer { listener.cancel() }
        if let pending { return pending }
        return try await withCheckedThrowingContinuation { cont in
            continuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if let c = self?.continuation {
                    self?.continuation = nil
                    c.resume(throwing: APIError(408, "Connexion Google expirée"))
                }
            }
        }
    }
}

@MainActor
enum GoogleAuth {
    static var clientId: String { (UserDefaults.standard.string(forKey: "googleClientId") ?? "").trimmingCharacters(in: .whitespaces) }
    static var clientSecret: String { (UserDefaults.standard.string(forKey: "googleClientSecret") ?? "").trimmingCharacters(in: .whitespaces) }
    static var email: String? { UserDefaults.standard.string(forKey: "googleEmail") }

    static let scopes = "openid email https://www.googleapis.com/auth/calendar.readonly"

    private static var accessToken: String?
    private static var expiry = Date.distantPast

    /// Refresh token stored in a 0600 file next to the database (Keychain prompts on every ad-hoc rebuild).
    private static var tokenFile: URL { Store.shared.supportDir.appendingPathComponent("google.json") }

    static var refreshToken: String? {
        get {
            guard let d = try? Data(contentsOf: tokenFile),
                  let j = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return nil }
            return j["refresh_token"]
        }
        set {
            if let newValue {
                let d = try? JSONSerialization.data(withJSONObject: ["refresh_token": newValue])
                try? d?.write(to: tokenFile)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
            } else {
                try? FileManager.default.removeItem(at: tokenFile)
            }
        }
    }

    static var isConnected: Bool { refreshToken != nil }

    private static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func random(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }

    static func signIn() async throws -> String {
        guard !clientId.isEmpty else { throw APIError(400, "Renseigne le Client ID Google (Réglages)") }
        let verifier = random(48)
        let challenge = base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
        let state = random(16)
        let loopback = try OAuthLoopback()
        let port = try await loopback.start()
        let redirect = "http://127.0.0.1:\(port)"

        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "consent"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)
        let query = try await loopback.waitForRedirect()
        if let err = query["error"] { throw APIError(401, "Google a refusé l'accès : \(err)") }
        guard query["state"] == state, let code = query["code"] else { throw APIError(400, "Réponse OAuth invalide") }

        let json = try await tokenRequest([
            "code": code, "client_id": clientId, "client_secret": clientSecret,
            "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier,
        ])
        guard let refresh = json["refresh_token"] as? String else { throw APIError(502, "Google n'a pas renvoyé de refresh token") }
        refreshToken = refresh
        store(json)
        let mail = (json["id_token"] as? String).flatMap(emailFromIDToken) ?? "compte Google"
        UserDefaults.standard.set(mail, forKey: "googleEmail")
        return mail
    }

    static func signOut() {
        refreshToken = nil
        accessToken = nil
        UserDefaults.standard.removeObject(forKey: "googleEmail")
    }

    static func token() async throws -> String {
        if let accessToken, expiry > Date().addingTimeInterval(60) { return accessToken }
        guard let refresh = refreshToken else { throw APIError(401, "Google Agenda non connecté") }
        let json = try await tokenRequest([
            "client_id": clientId, "client_secret": clientSecret, "refresh_token": refresh, "grant_type": "refresh_token",
        ])
        store(json)
        guard let t = accessToken else { throw APIError(401, "Jeton Google invalide, reconnecte-toi") }
        return t
    }

    private static func store(_ json: [String: Any]) {
        accessToken = json["access_token"] as? String
        expiry = Date().addingTimeInterval(TimeInterval(json["expires_in"] as? Int ?? 3600))
    }

    private static func tokenRequest(_ form: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            if json["error"] as? String == "invalid_grant" { signOut() }
            throw APIError(401, "Google : \(json["error_description"] as? String ?? json["error"] as? String ?? "erreur")")
        }
        return json
    }

    private static func emailFromIDToken(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var s = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let d = Data(base64Encoded: s), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
        return j["email"] as? String
    }
}

// MARK: - Calendar API

struct GCalendar: Identifiable, Hashable {
    let id: String
    let summary: String
    let color: String
    let primary: Bool
}

struct CalendarEvent: Identifiable, Hashable {
    let id: String
    let calendarId: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    let location: String?
    let meetURL: String?
    let htmlLink: String?
    let color: String
    let busy: Bool
    var details: String? = nil
    var attendees: [String] = []

    var duration: TimeInterval { end.timeIntervalSince(start) }
    var isNow: Bool { !allDay && start <= Date() && end > Date() }
}

@MainActor
enum GoogleCalendar {
    /// Calendars to show (ids). Empty = primary only.
    static var selectedIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "googleCalendars") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "googleCalendars") }
    }

    private static func get(_ path: String, _ query: [String: String] = [:]) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3" + path)!
        if !query.isEmpty { comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(try await GoogleAuth.token())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            let msg = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            throw APIError(502, "Google Agenda : \(msg)")
        }
        return json
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
    }

    static func calendars() async throws -> [GCalendar] {
        let json = try await get("/users/me/calendarList")
        return (json["items"] as? [[String: Any]] ?? []).map {
            GCalendar(id: $0["id"] as? String ?? "", summary: $0["summaryOverride"] as? String ?? $0["summary"] as? String ?? "",
                      color: $0["backgroundColor"] as? String ?? "#4F7CFF", primary: $0["primary"] as? Bool ?? false)
        }
        .sorted { ($0.primary ? 0 : 1, $0.summary) < ($1.primary ? 0 : 1, $1.summary) }
    }

    static func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        let ids = selectedIds.isEmpty ? ["primary"] : selectedIds
        let colors = Dictionary((try? await calendars())?.map { ($0.id, $0.color) } ?? [], uniquingKeysWith: { a, _ in a })
        let iso = ISO8601DateFormatter()
        var out: [CalendarEvent] = []
        for cal in ids {
            let enc = cal.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "@#"))) ?? cal
            let json = try await get("/calendars/\(enc)/events", [
                "timeMin": iso.string(from: from), "timeMax": iso.string(from: to),
                "singleEvents": "true", "orderBy": "startTime", "maxResults": "250",
            ])
            for e in json["items"] as? [[String: Any]] ?? [] {
                if e["status"] as? String == "cancelled" { continue }
                let me = (e["attendees"] as? [[String: Any]])?.first { $0["self"] as? Bool == true }
                if me?["responseStatus"] as? String == "declined" { continue }
                let s = e["start"] as? [String: Any] ?? [:]
                let en = e["end"] as? [String: Any] ?? [:]
                let allDay = s["date"] != nil
                guard let start = parseDate(s["dateTime"] ?? s["date"]), let end = parseDate(en["dateTime"] ?? en["date"]) else { continue }
                let meet = (e["hangoutLink"] as? String)
                    ?? ((e["conferenceData"] as? [String: Any])?["entryPoints"] as? [[String: Any]])?
                        .first { $0["entryPointType"] as? String == "video" }?["uri"] as? String
                out.append(CalendarEvent(
                    id: e["id"] as? String ?? UUID().uuidString, calendarId: cal,
                    title: e["summary"] as? String ?? "(Sans titre)", start: start, end: end, allDay: allDay,
                    location: e["location"] as? String, meetURL: meet, htmlLink: e["htmlLink"] as? String,
                    color: colors[cal] ?? colors["primary"] ?? "#4F7CFF",
                    busy: e["transparency"] as? String != "transparent",
                    details: (e["description"] as? String).map(stripHTML),
                    attendees: (e["attendees"] as? [[String: Any]] ?? []).filter { $0["self"] as? Bool != true }
                        .compactMap { ($0["displayName"] as? String) ?? ($0["email"] as? String) }))
            }
        }
        return out.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }
}

// MARK: - Work hours & free time

enum WorkHours {
    static var start: (Int, Int) { parse(UserDefaults.standard.string(forKey: "workStart") ?? "09:00") ?? (9, 0) }
    static var end: (Int, Int) { parse(UserDefaults.standard.string(forKey: "workEnd") ?? "18:30") ?? (18, 30) }

    static func parse(_ s: String) -> (Int, Int)? {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }

    static func bounds(on day: Date) -> (Date, Date) {
        let cal = Calendar.app
        let s = cal.date(bySettingHour: start.0, minute: start.1, second: 0, of: day)!
        let e = cal.date(bySettingHour: end.0, minute: end.1, second: 0, of: day)!
        return (s, e)
    }
}

extension Store {
    /// Remaining free slots today between now (or work start) and work end, minus busy events.
    func freeSlots(events: [CalendarEvent], on day: Date = Date()) -> [(Date, Date)] {
        var (from, to) = WorkHours.bounds(on: day)
        if Calendar.app.isDateInToday(day) { from = max(from, Date()) }
        guard from < to else { return [] }
        let busy = events.filter { !$0.allDay && $0.busy && $0.end > from && $0.start < to }
            .map { (max($0.start, from), min($0.end, to)) }
            .sorted { $0.0 < $1.0 }
        var slots: [(Date, Date)] = []
        var cursor = from
        for b in busy {
            if b.0 > cursor { slots.append((cursor, b.0)) }
            cursor = max(cursor, b.1)
        }
        if cursor < to { slots.append((cursor, to)) }
        return slots.filter { $0.1.timeIntervalSince($0.0) >= 15 * 60 }
    }

    func refreshCalendar() async {
        guard !Demo.active, Agenda.isAvailable else { todayEvents = []; calendarError = nil; return }
        let cal = Calendar.app
        let start = cal.startOfDay(for: Date())
        do {
            todayEvents = try await Agenda.events(from: start, to: cal.date(byAdding: .day, value: 1, to: start)!)
            calendarError = nil
            await autoPrepareMeetings()
        } catch {
            calendarError = (error as? APIError)?.message ?? error.localizedDescription
        }
    }

    func startCalendarPolling() {
        Task {
            // first launch: ask for Calendar access (macOS prompt), then load
            if AppleCalendar.enabled && AppleCalendar.status == .notDetermined { await AppleCalendar.requestAccess() }
            await refreshCalendar()
        }
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: AppleCalendar.store, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refreshCalendar() }
        }
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refreshCalendar() }
        }
    }

    /// Creates a time entry from a calendar event (idempotent on title + start).
    @discardableResult
    func logEvent(_ e: CalendarEvent, projectId: String?) -> TimeEntry {
        if let existing = entries.first(where: { $0.start == e.start && $0.description == e.title }) {
            var x = existing
            x.projectId = projectId
            return upsertEntry(x)
        }
        return upsertEntry(TimeEntry(description: e.title, projectId: projectId, start: e.start,
                                     end: min(e.end, Date()), tags: ["Agenda"]))
    }

    func isLogged(_ e: CalendarEvent) -> Bool {
        entries.contains { $0.start == e.start && $0.description == e.title }
    }
}
