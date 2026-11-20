import SwiftUI

struct AssistantView: View {
    @EnvironmentObject var store: Store
    @StateObject private var chat = ChatModel.shared
    @State private var input = ""
    @FocusState private var focused: Bool

    private var starters: [(String, String)] { [
        ("sun.max", "Qu'est-ce que je fais maintenant ?"),
        ("envelope", "Résume mes mails non lus importants"),
        ("ticket", store.tasks.last { $0.jiraKey != nil && $0.status != .done }?.jiraKey.map { "Où en est \($0) ?" } ?? "Où en sont mes tâches en cours ?"),
        ("calendar", "Prépare-moi pour ma prochaine réunion"),
        ("exclamationmark.triangle", "Qu'est-ce qui est en retard ?"),
        ("doc.text", "Combien d'heures j'ai fait cette semaine ?"),
    ] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if chat.messages.isEmpty { welcome }
                        ForEach(chat.messages) { m in
                            MessageBubble(message: m, streaming: chat.generating && m.id == chat.messages.last?.id)
                                .id(m.id)
                        }
                        if let e = chat.error {
                            Label(e, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(24)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: chat.messages.last?.content) { proxy.scrollTo("bottom", anchor: .bottom) }
                .onChange(of: chat.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            composer
        }
        .navigationTitle("Assistant")
        .toolbar {
            ToolbarItemGroup {
                OllamaToggle(compact: true)
                Button {
                    let n = store.upsertNote(Note(title: "Discussion avec l'assistant · \(Fmt.date(Date()))",
                                                  body: chat.transcriptMarkdown(), labels: Array(store.activeFacets)))
                    store.showToast("✓ Discussion enregistrée en note")
                    UserDefaults.standard.set(n.id, forKey: "notes.selected")
                } label: { Label("Enregistrer en note", systemImage: "note.text.badge.plus") }
                .disabled(chat.messages.isEmpty || chat.generating)
                Button { chat.reset() } label: { Label("Nouvelle discussion", systemImage: "square.and.pencil") }
                    .disabled(chat.messages.isEmpty)
            }
        }
        .onAppear { focused = true }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(LinearGradient(colors: [Color(hex: "#9B5CFF"), Color(hex: "#4F7CFF")], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ton assistant").font(.title2.weight(.bold))
                    Text("\(Ollama.model) · en local · connaît tes tâches, ton agenda, tes notes et tes mails")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(starters, id: \.1) { icon, text in
                    Button { chat.send(text, store: store) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon).foregroundStyle(Color.accentColor).frame(width: 20)
                            Text(text).multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            if !store.activeFacets.isEmpty {
                Label("Facette active : \(store.activeFacets.sorted().joined(separator: ", ")) — l'assistant se concentre dessus.", systemImage: "line.3.horizontal.decrease.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 30)
    }

    private var composer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Écris à ton assistant… (Entrée pour envoyer, ⇧Entrée pour aller à la ligne)", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { return .ignored }
                        submit()
                        return .handled
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1)))
                if chat.generating {
                    CircleIconButton(systemImage: "stop.fill", colors: [Color(hex: "#FF5C5C"), Color(hex: "#E8336D")], size: 40) { chat.stop() }
                        .help("Arrêter")
                } else {
                    CircleIconButton(systemImage: "arrow.up", size: 40) { submit() }
                        .opacity(input.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .frame(maxWidth: 908)
            .frame(maxWidth: .infinity)
        }
        .background(.bar)
    }

    private func submit() {
        let text = input
        input = ""
        chat.send(text, store: store)
    }
}

struct MessageBubble: View {
    let message: ChatMessage
    let streaming: Bool

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.accentColor.gradient))
            }
        } else {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(LinearGradient(colors: [Color(hex: "#9B5CFF"), Color(hex: "#4F7CFF")], startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 10) {
                    if message.content.isEmpty && streaming {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Réflexion…").foregroundStyle(.secondary)
                        }
                    } else if streaming {
                        // plain text while streaming (cheap), formatted once complete
                        Text(message.content).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        MarkdownPreview(text: message.content)
                    }
                    if !message.actions.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(message.actions, id: \.self) { Pill(text: $0, color: .green, systemImage: "checkmark.circle.fill") }
                        }
                    }
                    if !message.sources.isEmpty && !streaming {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(message.sources, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                            }
                        } label: {
                            Text("\(message.sources.count) source\(message.sources.count > 1 ? "s" : "") utilisée\(message.sources.count > 1 ? "s" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 40)
            }
        }
    }
}
