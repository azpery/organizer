import SwiftUI
import AppKit

struct GenerativeArtView: View {
    @EnvironmentObject var store: Store
    @AppStorage("art.style") private var styleRaw = ArtStyle.flow.rawValue
    @AppStorage("art.palette") private var paletteName = ArtPalette.all[0].name
    @AppStorage("art.seed") private var seed = 20_261_120
    @AppStorage("art.density") private var density = 0.5
    @AppStorage("art.format") private var formatRaw = ArtFormat.square.rawValue
    @AppStorage("art.animate") private var animate = false
    @AppStorage("art.speed") private var speed = 1.0
    @State private var history: [Int] = []
    /// Animation clock: `clock` seconds were reached at `anchor`; it keeps running from there while animating.
    @State private var clock = 0.0
    @State private var anchor = Date()

    private var style: ArtStyle { ArtStyle(rawValue: styleRaw) ?? .flow }
    private var format: ArtFormat { ArtFormat(rawValue: formatRaw) ?? .square }
    private var palette: ArtPalette { ArtPalette.all.first { $0.name == paletteName } ?? ArtPalette.all[0] }
    private func time(at date: Date = Date()) -> Double {
        animate ? clock + date.timeIntervalSince(anchor) * speed : clock
    }
    private func config(at date: Date = Date()) -> ArtConfig {
        ArtConfig(style: style, palette: palette, seed: UInt64(bitPattern: Int64(seed)), density: density, time: time(at: date))
    }
    private var config: ArtConfig { config() }

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Color.primary.opacity(0.03)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { timeline in
                    ArtCanvas(config: config(at: timeline.date)).equatable()
                }
                    .aspectRatio(format.ratio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    .padding(32)
                    .onTapGesture { reroll() }
                    .help("Clic : nouvelle variation")
            }
            Divider()
            inspector.frame(width: 250)
        }
        .navigationTitle("Generative art")
        .toolbar {
            ToolbarItemGroup {
                Button { toggleAnimation() } label: { Label(animate ? "Pause" : "Animer", systemImage: animate ? "pause.fill" : "play.fill") }
                    .keyboardShortcut(.space, modifiers: []).help(animate ? "Mettre en pause (Espace)" : "Animer (Espace)")
                Button { back() } label: { Label("Précédente", systemImage: "arrow.uturn.backward") }
                    .disabled(history.isEmpty).help("Revenir à la variation précédente")
                Button { reroll() } label: { Label("Nouvelle variation", systemImage: "dice") }
                    .keyboardShortcut("r", modifiers: .command).help("Nouvelle variation (⌘R)")
                Button { surprise() } label: { Label("Surprends-moi", systemImage: "sparkles") }
                    .help("Style, palette et variation au hasard")
            }
        }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group("Style") {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                        ForEach(ArtStyle.allCases) { s in
                            Button { styleRaw = s.rawValue } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: s.icon).font(.system(size: 17))
                                    Text(s.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 9)
                                .foregroundStyle(s == style ? Color.white : Color.primary)
                                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(s == style ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                group("Palette") {
                    VStack(spacing: 6) {
                        ForEach(ArtPalette.all) { p in
                            Button { paletteName = p.name } label: {
                                HStack(spacing: 8) {
                                    HStack(spacing: 0) {
                                        Color(hex: p.background)
                                        ForEach(p.colors, id: \.self) { Color(hex: $0) }
                                    }
                                    .frame(width: 96, height: 18)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.15)))
                                    Text(p.name).font(.callout)
                                    Spacer()
                                    if p == palette { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(Color.accentColor) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                group("Densité") {
                    Slider(value: $density, in: 0...1)
                }
                group("Animation") {
                    Toggle("Animer", isOn: Binding(get: { animate }, set: { _ in toggleAnimation() }))
                        .toggleStyle(.switch).controlSize(.small)
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise").foregroundStyle(.secondary)
                        Slider(value: Binding(get: { speed }, set: { setSpeed($0) }), in: 0.2...3)
                        Image(systemName: "hare").foregroundStyle(.secondary)
                    }
                    .disabled(!animate)
                    HStack {
                        Text(animate ? "En mouvement" : clock == 0 ? "Image fixe" : "En pause — l'export garde cette image")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if clock != 0 || animate {
                            Button("Réinitialiser") { clock = 0; anchor = Date() }.buttonStyle(.link).font(.caption)
                        }
                    }
                }
                group("Format") {
                    Picker("", selection: $formatRaw) {
                        ForEach(ArtFormat.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                group("Variation") {
                    HStack {
                        TextField("Graine", value: $seed, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).monospacedDigit()
                        Button { reroll() } label: { Image(systemName: "dice") }
                    }
                    Text("Une même graine redonne toujours la même image.").font(.caption).foregroundStyle(.secondary)
                }
                Divider()
                VStack(spacing: 8) {
                    Button { export() } label: { Label("Exporter en PNG…", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                    Button { copy() } label: { Label("Copier l'image", systemImage: "doc.on.doc").frame(maxWidth: .infinity) }
                    Button { setWallpaper() } label: { Label("Mettre en fond d'écran", systemImage: "desktopcomputer").frame(maxWidth: .infinity) }
                }
                .controlSize(.large)
            }
            .padding(16)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Actions

    private func toggleAnimation() {
        let now = Date()
        if animate { clock = time(at: now); animate = false }
        else { anchor = now; animate = true }
    }

    private func setSpeed(_ v: Double) {
        let now = Date()
        if animate { clock = time(at: now); anchor = now }
        speed = v
    }

    private func reroll() {
        history.append(seed)
        if history.count > 50 { history.removeFirst() }
        seed = Int.random(in: 1...999_999_999)
    }

    private func back() {
        if let s = history.popLast() { seed = s }
    }

    private func surprise() {
        styleRaw = ArtStyle.allCases.randomElement()!.rawValue
        paletteName = ArtPalette.all.randomElement()!.name
        density = Double.random(in: 0.25...0.9)
        reroll()
    }

    private func pixelSize(longSide: Double = 3200) -> CGSize {
        let r = format.ratio
        return r >= 1 ? CGSize(width: longSide, height: (longSide / r).rounded()) : CGSize(width: (longSide * r).rounded(), height: longSide)
    }

    private var fileName: String { "art-\(style.rawValue)-\(seed).png" }

    private func export() {
        guard let data = ArtRenderer.png(config, pixels: pixelSize()) else { store.showToast("Export impossible"); return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [.png]
        panel.directoryURL = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            store.showToast("✓ Image exportée (\(Int(pixelSize().width)) × \(Int(pixelSize().height)) px)")
        } catch {
            store.showToast("Export impossible : \(error.localizedDescription)")
        }
    }

    private func copy() {
        guard let data = ArtRenderer.png(config, pixels: pixelSize()), let image = NSImage(data: data) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
        store.showToast("✓ Image copiée")
    }

    private func setWallpaper() {
        let screens = NSScreen.screens
        guard let main = NSScreen.main ?? screens.first else { return }
        let px = CGSize(width: main.frame.width * main.backingScaleFactor, height: main.frame.height * main.backingScaleFactor)
        guard let data = ArtRenderer.png(config, pixels: px) else { store.showToast("Rendu impossible"); return }
        do {
            let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Organizer/Wallpapers", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName)
            try data.write(to: url)
            for s in screens { try NSWorkspace.shared.setDesktopImageURL(url, for: s, options: [:]) }
            store.showToast("✓ Fond d'écran mis à jour")
        } catch {
            store.showToast("Fond d'écran impossible : \(error.localizedDescription)")
        }
    }
}
