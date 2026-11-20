import EventKit
import AppKit

/// macOS Calendar (EventKit): every account configured in Calendar.app (iCloud, Google, Exchange, CalDAV…).
@MainActor
enum AppleCalendar {
    static let store = EKEventStore()

    struct Cal: Identifiable, Hashable {
        let id: String
        let title: String
        let source: String
        let color: String
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "appleCalendarEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "appleCalendarEnabled") }
    }

    /// Calendars to read (identifiers). Empty = all.
    static var selectedIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: "appleCalendars") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "appleCalendars") }
    }

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var authorized: Bool { status == .fullAccess || status == .authorized }
    static var isActive: Bool { enabled && authorized }

    static var statusLabel: String {
        switch status {
        case .fullAccess, .authorized: "Accès autorisé"
        case .denied: "Accès refusé — Réglages Système › Confidentialité › Calendriers"
        case .restricted: "Accès restreint"
        case .writeOnly: "Accès en écriture seule — accorde l'accès complet dans Réglages Système"
        default: "Pas encore autorisé"
        }
    }

    @discardableResult
    static func requestAccess() async -> Bool {
        do {
            let ok = try await store.requestFullAccessToEvents()
            if ok { store.reset() }
            return ok
        } catch { return false }
    }

    static func calendars() -> [Cal] {
        guard authorized else { return [] }
        return store.calendars(for: .event)
            .map { Cal(id: $0.calendarIdentifier, title: $0.title, source: $0.source?.title ?? "", color: hex($0.color)) }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    private static func hex(_ c: NSColor?) -> String {
        guard let c = c?.usingColorSpace(.sRGB) else { return "#4F7CFF" }
        return String(format: "#%02X%02X%02X", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }

    private static let meetPattern = try! NSRegularExpression(
        pattern: #"https://(meet\.google\.com/[a-z\-]+|[\w.]*zoom\.us/j/\S+|teams\.microsoft\.com/l/meetup-join/\S+|whereby\.com/\S+)"#,
        options: .caseInsensitive)

    private static func meetURL(in texts: [String?]) -> String? {
        for t in texts.compactMap({ $0 }) {
            if let m = meetPattern.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range, in: t) {
                return String(t[r]).trimmingCharacters(in: CharacterSet(charactersIn: ">)\"'"))
            }
        }
        return nil
    }

    static func events(from: Date, to: Date) -> [CalendarEvent] {
        guard isActive else { return [] }
        let all = store.calendars(for: .event)
        let selected = selectedIds.isEmpty ? all : all.filter { selectedIds.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: selected)
        return store.events(matching: predicate).compactMap { e -> CalendarEvent? in
            if e.status == .canceled { return nil }
            let me = e.attendees?.first { $0.isCurrentUser }
            if me?.participantStatus == .declined { return nil }
            let attendees = (e.attendees ?? []).filter { !$0.isCurrentUser }.compactMap { p -> String? in
                if let n = p.name, !n.isEmpty { return n }
                return p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            }
            return CalendarEvent(
                id: "apple:" + (e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString) + ":\(Int(e.startDate.timeIntervalSince1970))",
                calendarId: e.calendar.calendarIdentifier,
                title: e.title?.isEmpty == false ? e.title! : "(Sans titre)",
                start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                location: e.location?.isEmpty == false ? e.location : nil,
                meetURL: meetURL(in: [e.url?.absoluteString, e.location, e.notes]),
                htmlLink: nil,
                color: hex(e.calendar.color),
                busy: e.availability != .free,
                details: e.notes,
                attendees: attendees)
        }
    }
}

/// Unified agenda: Apple Calendar + Google Calendar (deduplicated when the same account is in both).
@MainActor
enum Agenda {
    static var isAvailable: Bool { AppleCalendar.isActive || GoogleAuth.isConnected }

    static func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var out = AppleCalendar.events(from: from, to: to)
        var googleError: Error?
        if GoogleAuth.isConnected {
            do {
                let g = try await GoogleCalendar.events(from: from, to: to)
                let seen = Set(out.map { key($0) })
                out += g.filter { !seen.contains(key($0)) }
            } catch { googleError = error }
        }
        if out.isEmpty, let googleError { throw googleError }
        // keep one copy of events shared between several calendars (invitations)
        var unique: [String: CalendarEvent] = [:]
        for e in out where unique[key(e)] == nil { unique[key(e)] = e }
        return unique.values.sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
    }

    private static func key(_ e: CalendarEvent) -> String {
        e.title.lowercased().trimmingCharacters(in: .whitespaces) + "|\(Int(e.start.timeIntervalSince1970 / 60))"
    }
}
