import SwiftUI

struct NotesView: View {
    @EnvironmentObject var store: Store
    @AppStorage("notes.selected") private var selectedId = ""
    @State private var search = ""

    private var notes: [Note] {
        store.notes.filter { n in
            store.inFacets(n.labels)
                && (search.isEmpty || n.title.localizedCaseInsensitiveContains(search) || n.body.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let list = notes
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                FacetBar(selected: $store.activeFacets).padding(.vertical, 12)
                if list.isEmpty {
                    Spacer()
                    EmptyState(icon: "note.text", title: "Aucune note", message: "Crée une note avec ＋. Elle reprend les facettes actives.")
                    Spacer()
                } else {
                    List(selection: Binding(get: { selectedId.isEmpty ? nil : selectedId }, set: { selectedId = $0 ?? "" })) {
                        ForEach(list) { n in NoteRow(note: n).tag(n.id) }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { ids in
                        if let id = ids.first, let n = store.note(id) {
                            Button(n.pinned ? "Désépingler" : "Épingler") { var c = n; c.pinned.toggle(); store.upsertNote(c, touch: false) }
                            Divider()
                            Button("Supprimer", role: .destructive) { store.deleteNote(id) }
                        }
                    }
                }
            }
            .frame(width: 300)
            .background(Color.primary.opacity(0.025))

            Divider()

            if let n = store.note(selectedId) {
                NoteEditor(note: n).id(n.id)
            } else {
                EmptyState(icon: "square.and.pencil", title: "Sélectionne ou crée une note")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Notes")
        .searchable(text: $search, placement: .toolbar, prompt: "Rechercher dans les notes")
        .toolbar {
            Button {
                let n = store.upsertNote(Note(title: "Nouvelle note", labels: Array(store.activeFacets).sorted()))
                selectedId = n.id
            } label: { Label("Nouvelle note", systemImage: "square.and.pencil") }
        }
    }
}

struct NoteRow: View {
    @EnvironmentObject var store: Store
    let note: Note

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if note.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.orange) }
                if note.isAppleNote { Image(systemName: "applelogo").font(.caption2).foregroundStyle(.secondary) }
                Text(note.title.isEmpty ? "Sans titre" : note.title).font(.body.weight(.semibold)).lineLimit(1)
            }
            Text(preview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack(spacing: 4) {
                Text(Fmt.dayHeader(note.updatedAt)).font(.caption2).foregroundStyle(.tertiary)
                ForEach(note.labels.prefix(2), id: \.self) { LabelChip(name: $0, compact: true) }
                if let key = store.task(note.taskId)?.jiraKey { Pill(text: key, color: .blue) }
            }
        }
        .padding(.vertical, 4)
    }

    private var preview: String {
        note.body.split(separator: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "#-*> ")) }
            .first { !$0.isEmpty } ?? "Note vide"
    }
}

struct NoteEditor: View {
    @EnvironmentObject var store: Store
    @State private var note: Note
    @State private var preview: Bool

    /// Notes with content open rendered; empty/new notes open in edit mode.
    init(note: Note) {
        _note = State(initialValue: note)
        _preview = State(initialValue: !note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Titre", text: $note.title)
                    .disabled(note.isAppleNote)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .bold))
                HStack(spacing: 12) {
                    TaskLinkPicker(taskId: $note.taskId).fixedSize()
                    Toggle(isOn: $note.pinned) { Image(systemName: "pin") }
                        .toggleStyle(.button)
                        .help("Épingler")
                    Spacer()
                    if !note.isAppleNote {
                    Picker("", selection: $preview) {
                        Text("Édition").tag(false)
                        Text("Aperçu").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    }
                }
                FacetChipsEditor(labels: $note.labels)
                HStack {
                    Text("Modifiée \(Fmt.dayHeader(note.updatedAt).lowercased()) à \(Fmt.time(note.updatedAt))")
                        .font(.caption).foregroundStyle(.tertiary)
                    if note.isAppleNote, let ext = note.externalId {
                        Spacer()
                        Label("Liée à Apple Notes · lecture seule", systemImage: "link").font(.caption).foregroundStyle(.secondary)
                        Button("Ouvrir dans Notes") { AppleNotes.show(ext) }.controlSize(.small)
                    }
                }
            }
            .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 12)

            Divider().padding(.horizontal, 28)

            if preview || note.isAppleNote {
                ScrollView {
                    MarkdownPreview(text: note.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 28).padding(.vertical, 16)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !note.isAppleNote { preview = false } }
                }
            } else {
                TextEditor(text: $note.body)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 23).padding(.vertical, 12)
            }
        }
        .onChange(of: note) { old, new in
            if old.id == new.id { store.upsertNote(new) }
        }
    }
}

/// Markdown rendering: headings, lists (nested, ordered, tasks), quotes/panels, code blocks, rules, tables, inline styles.
struct MarkdownPreview: View {
    let text: String

    private enum Block: Hashable {
        case heading(Int, String)
        case bullet(Int, String)
        case ordered(Int, String, String)
        case task(Int, Bool, String)
        case quote([String])
        case code(String)
        case table([[String]])
        case rule
        case paragraph(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var lines = text.components(separatedBy: "\n")[...]
        while let raw = lines.first {
            lines = lines.dropFirst()
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                var code: [String] = []
                while let l = lines.first, !l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { code.append(l); lines = lines.dropFirst() }
                lines = lines.dropFirst()
                out.append(.code(code.joined(separator: "\n")))
            } else if line.hasPrefix(">") {
                var q = [String(line.dropFirst()).trimmingCharacters(in: .whitespaces)]
                while let l = lines.first, l.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    q.append(String(l.trimmingCharacters(in: .whitespaces).dropFirst()).trimmingCharacters(in: .whitespaces))
                    lines = lines.dropFirst()
                }
                out.append(.quote(q))
            } else if line.hasPrefix("|") {
                var rows = [line]
                while let l = lines.first, l.trimmingCharacters(in: .whitespaces).hasPrefix("|") { rows.append(l.trimmingCharacters(in: .whitespaces)); lines = lines.dropFirst() }
                let cells = rows.filter { !$0.contains("---") }.map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "|")).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
                out.append(.table(cells))
            } else if line == "---" || line == "***" {
                out.append(.rule)
            } else if line.hasPrefix("### ") { out.append(.heading(3, String(line.dropFirst(4))))
            } else if line.hasPrefix("## ") { out.append(.heading(2, String(line.dropFirst(3))))
            } else if line.hasPrefix("# ") { out.append(.heading(1, String(line.dropFirst(2))))
            } else if line.hasPrefix("- [ ] ") || line.lowercased().hasPrefix("- [x] ") {
                out.append(.task(indent, !line.hasPrefix("- [ ]"), String(line.dropFirst(6))))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(indent, String(line.dropFirst(2))))
            } else if let r = line.range(of: "^\\d+[.)] ", options: .regularExpression) {
                out.append(.ordered(indent, String(line[r]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...])))
            } else if !line.isEmpty {
                out.append(.paragraph(line))
            }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in view(b) }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ b: Block) -> some View {
        switch b {
        case .heading(let level, let t):
            inline(t).font(level == 1 ? .title2.weight(.bold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, level == 1 ? 8 : 4)
        case .bullet(let indent, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                inline(t).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .ordered(let indent, let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).foregroundStyle(.secondary).monospacedDigit()
                inline(t).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .task(let indent, let done, let t):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .foregroundStyle(done ? Color.green : .secondary)
                inline(t).strikethrough(done, color: .secondary).foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 18)
        case .quote(let lines):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                    if !l.isEmpty { inline(l).fixedSize(horizontal: false, vertical: true) }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.blue.opacity(0.08)))
            .overlay(alignment: .leading) {
                UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(Color.blue.opacity(0.6)).frame(width: 3)
            }
        case .code(let c):
            ScrollView(.horizontal) {
                Text(c).font(.system(.callout, design: .monospaced)).padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
        case .table(let rows):
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    GridRow { ForEach(Array(row.enumerated()), id: \.offset) { _, c in inline(c).fontWeight(i == 0 ? .semibold : .regular) } }
                    if i == 0 { Divider() }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
        case .rule:
            Divider().padding(.vertical, 4)
        case .paragraph(let t):
            inline(t).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ s: String) -> Text {
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return Text((try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s))
    }
}

enum AppleNotes {
    /// Opens the linked note in Notes.app.
    static func show(_ id: String) {
        let escaped = id.replacingOccurrences(of: "\"", with: "")
        let script = "tell application \"Notes\"\nactivate\nshow note id \"\(escaped)\"\nend tell"
        DispatchQueue.global().async {
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
        }
    }
}
