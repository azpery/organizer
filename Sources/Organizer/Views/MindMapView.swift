import SwiftUI

struct MindMapView: View {
    @EnvironmentObject var store: Store
    @AppStorage("mindmap.selected") private var selectedId = ""
    @State private var search = ""

    private var maps: [MindMap] {
        store.mindmaps
            .filter { store.inFacets($0.labels) }
            .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.nodes.contains { $0.text.localizedCaseInsensitiveContains(search) } }
    }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 240)
            Divider()
            if let m = store.mindmap(selectedId) {
                MindMapEditor(mapId: m.id).id(m.id)
            } else {
                VStack(spacing: 14) {
                    EmptyState(icon: "point.3.connected.trianglepath.dotted", title: "Aucune carte ouverte",
                               message: "Crée une carte mentale pour poser tes idées, découper un projet ou préparer une réunion.")
                    Button { create() } label: { Label("Nouvelle carte", systemImage: "plus") }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Mind mapping")
        .toolbar {
            ToolbarItem { Button { create() } label: { Label("Nouvelle carte", systemImage: "plus") }.keyboardShortcut("n", modifiers: [.command, .shift]) }
        }
        .onAppear {
            if store.mindmap(selectedId) == nil, let first = maps.first { selectedId = first.id }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            TextField("Rechercher", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(10)
            List(selection: Binding(get: { selectedId.isEmpty ? nil : selectedId }, set: { selectedId = $0 ?? "" })) {
                ForEach(maps) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.title).font(.body.weight(.medium)).lineLimit(1)
                        HStack(spacing: 6) {
                            Text("\(m.nodes.count - 1) idée\(m.nodes.count > 2 ? "s" : "")")
                            Text("·")
                            Text(Fmt.date(m.updatedAt))
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        if !m.labels.isEmpty {
                            Text(m.labels.joined(separator: ", ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 3)
                    .tag(m.id)
                    .contextMenu {
                        Button("Dupliquer") {
                            var copy = m
                            copy.id = UUID().uuidString
                            copy.title += " (copie)"
                            if let r = copy.root, let i = copy.index(r.id) { copy.nodes[i].text = copy.title }
                            copy.createdAt = Date()
                            selectedId = store.upsertMindMap(copy).id
                        }
                        Divider()
                        Button("Supprimer", role: .destructive) {
                            store.deleteMindMap(m.id)
                            if selectedId == m.id { selectedId = maps.first?.id ?? "" }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if maps.isEmpty {
                    Text(store.mindmaps.isEmpty ? "Aucune carte" : "Aucune carte dans ces facettes")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func create() {
        let m = store.upsertMindMap(MindMap(title: "Nouvelle carte", labels: store.activeFacets.sorted()))
        selectedId = m.id
        NotificationCenter.default.post(name: .mindMapEditRoot, object: m.id)
    }
}

extension Notification.Name {
    static let mindMapEditRoot = Notification.Name("mindMapEditRoot")
}

// MARK: - Editor

struct MindMapEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow
    let mapId: String

    @State private var selected: String?
    @State private var editingId: String?
    @State private var draft = ""
    @AppStorage("mindmap.zoom") private var zoom: Double = 1
    @State private var pinchBase: Double?
    @State private var undo: [MindMap] = []
    @State private var redo: [MindMap] = []
    @State private var expanding: String?
    @State private var dragId: String?
    @State private var dragOffset: CGSize = .zero
    @State private var showInfo = false
    @State private var viewport: CGSize = .zero
    @State private var didFit = false
    @FocusState private var canvasFocused: Bool
    @FocusState private var fieldFocused: Bool

    private var map: MindMap? { store.mindmap(mapId) }

    var body: some View {
        if let map {
            let layout = MindLayout(map: map, editingId: editingId, draft: draft)
            VStack(spacing: 0) {
                header(map)
                Divider()
                canvas(map, layout)
            }
            .onReceive(NotificationCenter.default.publisher(for: .mindMapEditRoot)) { note in
                if note.object as? String == mapId, let r = map.root { beginEdit(r.id, selectAll: true) }
            }
            .onAppear {
                if selected == nil { selected = map.root?.id }
                canvasFocused = true
            }
        }
    }

    // MARK: Header

    private func header(_ map: MindMap) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.purple)
            Text(map.title).font(.headline).lineLimit(1)
            FacetChipsEditor(labels: Binding(get: { store.mindmap(mapId)?.labels ?? [] },
                                             set: { l in mutate(record: false) { $0.labels = l } }))
                .frame(maxWidth: 380, alignment: .leading)
            Spacer()
            Group {
                Button { undoLast() } label: { Image(systemName: "arrow.uturn.backward") }
                    .keyboardShortcut("z").disabled(undo.isEmpty).help("Annuler (⌘Z)")
                Button { redoLast() } label: { Image(systemName: "arrow.uturn.forward") }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(redo.isEmpty).help("Rétablir (⇧⌘Z)")
                Divider().frame(height: 16)
                Button { zoom = max(0.3, zoom - 0.1) } label: { Image(systemName: "minus.magnifyingglass") }.keyboardShortcut("-")
                Text("\(Int(zoom * 100)) %").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 42)
                Button { zoom = min(2.5, zoom + 0.1) } label: { Image(systemName: "plus.magnifyingglass") }.keyboardShortcut("+")
                Button { fit() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.keyboardShortcut("9").help("Ajuster à la fenêtre (⌘9)")
                Button { zoom = 1 } label: { Image(systemName: "1.magnifyingglass") }.keyboardShortcut("0").help("Taille réelle (⌘0)")
                Divider().frame(height: 16)
                Button { exportNote(map) } label: { Label("En note", systemImage: "note.text.badge.plus") }
                    .help("Enregistrer la carte comme note (plan Markdown)")
                Button { showInfo.toggle() } label: { Image(systemName: "keyboard") }
                    .popover(isPresented: $showInfo) { shortcuts }
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Raccourcis").font(.headline).padding(.bottom, 4)
            ForEach([("⇥ Tab", "Ajouter une sous-idée"), ("↩ Entrée", "Ajouter une idée sœur"), ("Espace / double-clic", "Modifier le texte"),
                     ("⌫", "Supprimer la branche"), ("← → ↑ ↓", "Naviguer"), ("⌥↑ / ⌥↓", "Réordonner"), ("⌘.", "Replier / déplier"),
                     ("Glisser une idée sur une autre", "La déplacer"), ("⌘Z / ⇧⌘Z", "Annuler / rétablir"), ("Pincer / ⌘+ ⌘-", "Zoom")], id: \.0) { k, v in
                HStack {
                    Text(k).font(.callout.monospaced()).frame(width: 190, alignment: .leading)
                    Text(v).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
    }

    // MARK: Canvas

    private func canvas(_ map: MindMap, _ layout: MindLayout) -> some View {
        ScrollViewReader { proxy in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    edges(map, layout)
                    ForEach(map.nodes.filter { layout.frames[$0.id] != nil }) { n in
                        nodeView(n, map: map, layout: layout)
                    }
                    if let r = map.root, let f = layout.frames[r.id] {
                        Color.clear.frame(width: 1, height: 1).position(x: f.midX, y: f.midY).id("root")
                    }
                }
                .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
                .scaleEffect(zoom, anchor: .topLeading)
                .frame(width: layout.size.width * zoom, height: layout.size.height * zoom, alignment: .topLeading)
                .frame(minWidth: 600, minHeight: 400)
                .contentShape(Rectangle())
                .onTapGesture { commitEdit(); selected = nil; canvasFocused = true }
            }
            .background(dotGrid)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { viewport = g.size; autoFit(layout) }
                    .onChange(of: g.size) { _, s in viewport = s }
            })
            .gesture(MagnifyGesture()
                .onChanged { v in
                    if pinchBase == nil { pinchBase = zoom }
                    zoom = min(2.5, max(0.3, (pinchBase ?? 1) * v.magnification))
                }
                .onEnded { _ in pinchBase = nil })
            .onAppear { DispatchQueue.main.async { proxy.scrollTo("root", anchor: .center) } }
            .onChange(of: zoom) { DispatchQueue.main.async { proxy.scrollTo(selected ?? "root", anchor: .center) } }
        }
        .focusable()
        .focused($canvasFocused)
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press, map: map, layout: layout) }
    }

    private var dotGrid: some View {
        Canvas { ctx, size in
            let step: CGFloat = 22
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.09)))
                    x += step
                }
                y += step
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }

    private func edges(_ map: MindMap, _ layout: MindLayout) -> some View {
        Canvas { ctx, _ in
            for n in map.nodes {
                guard let pid = n.parentId, let f = layout.frames[n.id], let pf = layout.frames[pid] else { continue }
                let s = layout.side[n.id] ?? 1
                let d = layout.depth[n.id] ?? 1
                let offset = n.id == dragId ? dragOffset : .zero
                let start = CGPoint(x: s == 1 ? pf.maxX : pf.minX, y: pf.midY)
                let endFrame = f.offsetBy(dx: offset.width, dy: offset.height)
                let end = CGPoint(x: s == 1 ? endFrame.minX : endFrame.maxX, y: endFrame.midY)
                let start2 = d == 1 ? CGPoint(x: pf.midX + (pf.width / 2 - 6) * CGFloat(s), y: pf.midY) : start
                var p = Path()
                p.move(to: start2)
                let dx = (end.x - start2.x) * 0.5
                p.addCurve(to: end, control1: CGPoint(x: start2.x + dx, y: start2.y), control2: CGPoint(x: end.x - dx, y: end.y))
                let color = Color(hex: layout.color[n.id] ?? "#888888")
                ctx.stroke(p, with: .color(color.opacity(d == 1 ? 0.85 : 0.6)),
                           style: StrokeStyle(lineWidth: d == 1 ? 3 : d == 2 ? 2 : 1.4, lineCap: .round))
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func nodeView(_ n: MindNode, map: MindMap, layout: MindLayout) -> some View {
        let f = layout.frames[n.id]!
        let depth = layout.depth[n.id] ?? 0
        let color = Color(hex: layout.color[n.id] ?? "#5B5BD6")
        let isDragging = dragId == n.id
        MindNodeView(node: n, depth: depth, color: color,
                     selected: selected == n.id, editing: editingId == n.id,
                     task: n.taskId.flatMap { store.task($0) },
                     hasNote: n.noteId.flatMap { id in store.notes.first { $0.id == id } } != nil,
                     onOpenNote: { if let id = n.noteId { openNote(id) } },
                     hiddenCount: layout.hiddenCount[n.id] ?? 0,
                     side: layout.side[n.id] ?? 1,
                     busy: expanding == n.id,
                     draft: $draft, fieldFocused: $fieldFocused,
                     onCommit: { commitEdit(); canvasFocused = true },
                     onCancel: { editingId = nil; canvasFocused = true },
                     onTab: { commitEdit(); addChild(n.id) },
                     onToggle: { mutate { m in if let i = m.index(n.id) { m.nodes[i].collapsed.toggle() } } },
                     onOpenTask: { if let t = n.taskId { openWindow(id: "task", value: t) } })
            .frame(width: f.width, height: f.height)
            .position(x: f.midX + (isDragging ? dragOffset.width : 0), y: f.midY + (isDragging ? dragOffset.height : 0))
            .zIndex(isDragging ? 10 : editingId == n.id ? 5 : 1)
            .onTapGesture(count: 2) { beginEdit(n.id) }
            .onTapGesture { if editingId != n.id { commitEdit() }; selected = n.id; canvasFocused = editingId == nil }
            .gesture(n.parentId == nil || editingId == n.id ? nil : DragGesture(minimumDistance: 6)
                .onChanged { v in dragId = n.id; dragOffset = v.translation; selected = n.id }
                .onEnded { v in
                    let drop = CGPoint(x: f.midX + v.translation.width, y: f.midY + v.translation.height)
                    let excluded = Set(map.descendants(of: n.id) + [n.id])
                    if let target = layout.frames.first(where: { !excluded.contains($0.key) && $0.value.insetBy(dx: -6, dy: -6).contains(drop) })?.key {
                        mutate { $0.reparent(n.id, to: target) }
                    } else if let root = map.root, n.parentId == root.id, let rf = layout.frames[root.id] {
                        // dropped in empty space: a root branch can switch sides
                        let newSide = drop.x >= rf.midX ? 1 : -1
                        if newSide != layout.side[n.id] { mutate { m in if let i = m.index(n.id) { m.nodes[i].side = newSide } } }
                    }
                    dragId = nil
                    dragOffset = .zero
                })
            .contextMenu { menu(n, map: map) }
    }

    @ViewBuilder
    private func menu(_ n: MindNode, map: MindMap) -> some View {
        Button { addChild(n.id) } label: { Label("Ajouter une sous-idée", systemImage: "arrow.turn.down.right") }
        if n.parentId != nil {
            Button { addSibling(n.id) } label: { Label("Ajouter une idée sœur", systemImage: "plus") }
        }
        Button { beginEdit(n.id) } label: { Label("Modifier", systemImage: "pencil") }
        Button { expand(n.id) } label: { Label("Développer avec l'IA", systemImage: "sparkles") }
            .disabled(expanding != nil)
        Divider()
        if let nid = n.noteId, store.notes.contains(where: { $0.id == nid }) {
            Button { openNote(nid) } label: { Label("Ouvrir la note", systemImage: "note.text") }
        }
        if let t = n.taskId, let task = store.task(t) {
            Button { openWindow(id: "task", value: t) } label: { Label("Ouvrir « \(task.title) »", systemImage: "arrow.up.right.square") }
            Button { mutate { m in if let i = m.index(n.id) { m.nodes[i].taskId = nil } } } label: { Label("Délier la tâche", systemImage: "link.badge.minus") }
        } else if n.parentId != nil {
            Button { createTask(n) } label: { Label("Créer une tâche", systemImage: "checklist") }
            Menu {
                let candidates = store.tasks.filter { $0.status != .done && store.taskInFacets($0) }.sorted { $0.updatedAt > $1.updatedAt }.prefix(40)
                ForEach(Array(candidates)) { t in
                    Button("\(t.jiraKey.map { "\($0) · " } ?? "")\(t.title)") { mutate { m in if let i = m.index(n.id) { m.nodes[i].taskId = t.id } } }
                }
            } label: { Label("Lier à une tâche", systemImage: "link") }
        }
        Divider()
        Menu {
            Button("Automatique") { mutate { m in if let i = m.index(n.id) { m.nodes[i].colorHex = nil } } }
            ForEach(MindLayout.palette, id: \.self) { hex in
                Button { mutate { m in if let i = m.index(n.id) { m.nodes[i].colorHex = hex } } } label: {
                    Label { Text(colorName(hex)) } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(hex: hex)) }
                }
            }
        } label: { Label("Couleur", systemImage: "paintpalette") }
        if !map.children(of: n.id).isEmpty {
            Button { mutate { m in if let i = m.index(n.id) { m.nodes[i].collapsed.toggle() } } } label: {
                Label(n.collapsed ? "Déplier" : "Replier", systemImage: n.collapsed ? "chevron.down" : "chevron.up")
            }
        }
        if n.parentId != nil {
            Divider()
            Button(role: .destructive) { delete(n.id) } label: { Label("Supprimer la branche", systemImage: "trash") }
        }
    }

    private func openNote(_ id: String) {
        UserDefaults.standard.set(id, forKey: "notes.selected")
        UserDefaults.standard.set(SidebarItem.notes.rawValue, forKey: "sidebar")
    }

    private func colorName(_ hex: String) -> String {
        ["#7C5CFF": "Violet", "#FF6B6B": "Rouge", "#22B07D": "Vert", "#FF9F1C": "Orange", "#2E9BFF": "Bleu",
         "#E84393": "Rose", "#00B8A9": "Turquoise", "#A0785A": "Brun"][hex] ?? hex
    }

    // MARK: Actions

    private func fitZoom(_ layout: MindLayout) -> Double {
        guard viewport.width > 0, layout.size.width > 0 else { return 1 }
        let z = min(viewport.width / layout.size.width, viewport.height / layout.size.height)
        return min(1, max(0.3, Double(z) * 0.98))
    }

    private func fit() {
        guard let m = map else { return }
        zoom = fitZoom(MindLayout(map: m, editingId: nil, draft: ""))
    }

    /// On opening, shrink a map that does not fit the window (never enlarge).
    private func autoFit(_ layout: MindLayout) {
        guard !didFit else { return }
        didFit = true
        let z = fitZoom(layout)
        if z < zoom { zoom = z }
    }


    private func mutate(record: Bool = true, _ change: (inout MindMap) -> Void) {
        guard var m = store.mindmap(mapId) else { return }
        if record {
            undo.append(m)
            if undo.count > 80 { undo.removeFirst() }
            redo.removeAll()
        }
        change(&m)
        store.upsertMindMap(m)
    }

    private func undoLast() {
        guard let prev = undo.popLast(), let cur = map else { return }
        redo.append(cur)
        editingId = nil
        store.upsertMindMap(prev)
        if let s = selected, prev.node(s) == nil { selected = prev.root?.id }
    }

    private func redoLast() {
        guard let next = redo.popLast(), let cur = map else { return }
        undo.append(cur)
        editingId = nil
        store.upsertMindMap(next)
        if let s = selected, next.node(s) == nil { selected = next.root?.id }
    }

    private func beginEdit(_ id: String, selectAll: Bool = false) {
        commitEdit()
        guard let n = map?.node(id) else { return }
        selected = id
        draft = n.text
        editingId = id
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commitEdit() {
        guard let id = editingId else { return }
        editingId = nil
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let n = map?.node(id) else { return }
        if text.isEmpty {
            // an empty new idea is dropped; the root keeps its previous name
            if n.text.isEmpty && n.parentId != nil { mutate(record: false) { $0.remove(id) }; selected = n.parentId }
            return
        }
        if text != n.text { mutate { m in if let i = m.index(id) { m.nodes[i].text = text } } }
    }

    private func addChild(_ parent: String) {
        var newId: String?
        mutate { newId = $0.addChild(to: parent) }
        if let newId { beginEdit(newId) }
    }

    private func addSibling(_ id: String) {
        var newId: String?
        mutate { newId = $0.addSibling(after: id) }
        if let newId { beginEdit(newId) }
    }

    private func delete(_ id: String) {
        guard let m = map, let n = m.node(id), n.parentId != nil else { return }
        let sibs = m.children(of: n.parentId!)
        let pos = sibs.firstIndex { $0.id == id } ?? 0
        let next = sibs.indices.contains(pos + 1) ? sibs[pos + 1].id : pos > 0 ? sibs[pos - 1].id : n.parentId
        mutate { $0.remove(id) }
        selected = next
    }

    private func createTask(_ n: MindNode) {
        guard let m = map else { return }
        var t = TaskItem(title: n.text)
        t.labels = m.labels
        t.status = .todo
        t.context = .pro
        t.notes = "Issue de la carte « \(m.title) » : " + m.path(to: n.id).map(\.text).joined(separator: " › ")
        if let key = Jira.detectKey(in: n.text) { t.jiraKey = key; t.url = Jira.browseURL(key)?.absoluteString }
        let saved = store.upsertTask(t, syncToJira: false)
        mutate { mm in if let i = mm.index(n.id) { mm.nodes[i].taskId = saved.id } }
        store.showToast("✓ Tâche créée : \(n.text)")
    }

    private func expand(_ id: String) {
        guard let m = map else { return }
        expanding = id
        Task {
            do {
                let ideas = try await store.expandIdeas(map: m, nodeId: id)
                if ideas.isEmpty { store.showToast("Ollama n'a rien proposé") }
                else { mutate { mm in for idea in ideas { mm.addChild(to: id, text: idea) } } }
            } catch {
                store.showToast((error as? APIError)?.message ?? error.localizedDescription)
            }
            expanding = nil
        }
    }

    private func exportNote(_ m: MindMap) {
        let body = m.markdown(store: store)
        let externalId = "mindmap:\(m.id)"
        var note = store.notes.first { $0.externalId == externalId } ?? Note(title: "Carte · \(m.title)")
        note.title = "Carte · \(m.title)"
        note.body = body
        note.labels = m.labels
        note.externalId = externalId
        _ = store.upsertNote(note)
        store.showToast("✓ Carte enregistrée en note")
    }

    // MARK: Keyboard

    private func handleKey(_ press: KeyPress, map: MindMap, layout: MindLayout) -> KeyPress.Result {
        guard editingId == nil else { return .ignored }
        guard let sel = selected, let n = map.node(sel) else {
            if press.key == .tab || press.key == .return || press.key.character == " " { selected = map.root?.id; return .handled }
            return .ignored
        }
        let side = layout.side[sel] ?? 1
        switch press.key {
        case .tab:
            addChild(sel); return .handled
        case .return:
            if n.parentId == nil { addChild(sel) } else { addSibling(sel) }
            return .handled
        case .delete, .deleteForward:
            delete(sel); return .handled
        case .space:
            beginEdit(sel); return .handled
        case .escape:
            selected = nil; return .handled
        case .upArrow, .downArrow:
            let delta = press.key == .upArrow ? -1 : 1
            if press.modifiers.contains(.option) { mutate { $0.move(sel, by: delta) }; return .handled }
            selected = verticalNeighbour(of: sel, delta: delta, map: map, layout: layout) ?? sel
            return .handled
        case .leftArrow, .rightArrow:
            let dir = press.key == .rightArrow ? 1 : -1
            if n.parentId == nil {
                let kids = map.children(of: sel).filter { (layout.side[$0.id] ?? 1) == dir && layout.frames[$0.id] != nil }
                selected = kids.min { abs(layout.frames[$0.id]!.midY - layout.frames[sel]!.midY) < abs(layout.frames[$1.id]!.midY - layout.frames[sel]!.midY) }?.id ?? sel
            } else if dir == side {
                if n.collapsed { mutate { m in if let i = m.index(sel) { m.nodes[i].collapsed = false } } }
                selected = map.children(of: sel).first?.id ?? sel
            } else {
                selected = n.parentId
            }
            return .handled
        default:
            if press.key.character == "." && press.modifiers.contains(.command) {
                mutate { m in if let i = m.index(sel) { m.nodes[i].collapsed.toggle() } }
                return .handled
            }
            // typing a letter starts editing, replacing the text (like XMind)
            if press.modifiers.isDisjoint(with: [.command, .control]), let c = press.characters.first, c.isLetter || c.isNumber {
                beginEdit(sel)
                draft = press.characters
                return .handled
            }
            return .ignored
        }
    }

    /// Nearest visible node above/below on the same side, at the closest depth.
    private func verticalNeighbour(of id: String, delta: Int, map: MindMap, layout: MindLayout) -> String? {
        guard let f = layout.frames[id] else { return nil }
        let side = layout.side[id] ?? 1
        let depth = layout.depth[id] ?? 0
        let candidates = layout.frames.filter { k, v in
            k != id && (layout.side[k] ?? 0) == side && (delta < 0 ? v.midY < f.midY : v.midY > f.midY)
        }
        return candidates.min { a, b in
            let da = abs((layout.depth[a.key] ?? 0) - depth) * 400 + Int(abs(a.value.midY - f.midY))
            let db = abs((layout.depth[b.key] ?? 0) - depth) * 400 + Int(abs(b.value.midY - f.midY))
            return da < db
        }?.key
    }
}

// MARK: - Node

struct MindNodeView: View {
    let node: MindNode
    let depth: Int
    let color: Color
    let selected: Bool
    let editing: Bool
    let task: TaskItem?
    var hasNote = false
    var onOpenNote: () -> Void = {}
    let hiddenCount: Int
    let side: Int
    let busy: Bool
    @Binding var draft: String
    var fieldFocused: FocusState<Bool>.Binding
    let onCommit: () -> Void
    let onCancel: () -> Void
    let onTab: () -> Void
    let onToggle: () -> Void
    let onOpenTask: () -> Void

    private var radius: CGFloat { depth == 0 ? 16 : depth == 1 ? 12 : 8 }
    private var font: Font { Font(MindLayout.font(depth: depth)) }
    private var pad: CGSize { MindLayout.padding(depth: depth) }

    var body: some View {
        HStack(spacing: 6) {
            if let task {
                Button(action: onOpenTask) {
                    Image(systemName: task.status.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(depth == 0 ? .white : task.status.color)
                }
                .buttonStyle(.plain)
                .help("\(task.jiraKey.map { "\($0) · " } ?? "")\(task.status.label) — ouvrir la tâche")
            }
            if hasNote {
                Button(action: onOpenNote) {
                    Image(systemName: "note.text").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(depth == 0 ? .white : .secondary)
                }
                .buttonStyle(.plain)
                .help("Ouvrir la note")
            }
            if editing {
                TextField("Idée", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(font)
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(depth == 0 ? .center : .leading)
                    .focused(fieldFocused)
                    .onSubmit(onCommit)
                    .onKeyPress(.tab) { onTab(); return .handled }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        onCommit(); return .handled
                    }
                    .onExitCommand(perform: onCancel)
            } else {
                Text(node.text.isEmpty ? "Idée" : node.text)
                    .font(font)
                    .foregroundStyle(node.text.isEmpty ? textColor.opacity(0.4) : textColor)
                    .strikethrough(task?.status == .done, color: textColor.opacity(0.6))
                    .multilineTextAlignment(depth == 0 ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if busy { ProgressView().controlSize(.mini) }
        }
        .padding(.horizontal, pad.width).padding(.vertical, pad.height)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: depth == 0 ? .center : .leading)
        .background(background)
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : border, lineWidth: selected ? 2.5 : 1)
        )
        .shadow(color: .black.opacity(depth == 0 ? 0.18 : selected ? 0.12 : 0.05), radius: depth == 0 ? 10 : 4, y: 2)
        .overlay(alignment: side == -1 ? .leading : .trailing) {
            if hiddenCount > 0 {
                Button(action: onToggle) {
                    Text("\(hiddenCount)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(color))
                }
                .buttonStyle(.plain)
                .offset(x: side == -1 ? -14 : 14)
                .help("Déplier")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: radius))
    }

    private var textColor: Color { depth == 0 ? .white : .primary }

    private var border: Color {
        switch depth {
        case 0: .clear
        case 1: color.opacity(0.55)
        default: Color.primary.opacity(0.12)
        }
    }

    @ViewBuilder private var background: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        switch depth {
        case 0: shape.fill(LinearGradient(colors: [color, color.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing))
        case 1: shape.fill(Color(nsColor: .controlBackgroundColor)).overlay(shape.fill(color.opacity(0.14)))
        default: shape.fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}
