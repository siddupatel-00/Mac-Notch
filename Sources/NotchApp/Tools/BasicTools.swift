import SwiftUI

// MARK: Home
struct HomeTool: View {
    var body: some View {
        // ToolContainer intentionally skips titles (the panel header shows the
        // tool name), so the greeting is rendered here or Home is near-empty.
        ToolContainer("", subtitle: "how are you?") {
            Text("Hello there")
                .font(.title2).bold()
            Text(Date().formatted(date: .long, time: .shortened))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: Music
struct MusicTool: View {
    var body: some View {
        // No outer ScrollView — inner song Lists scroll themselves.
        MusicHubView()
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: Scratchpad
struct ScratchpadTool: View {
    @State private var text: String = UserDefaults.standard.string(forKey: "scratchpad") ?? ""
    var body: some View {
        ToolContainer("Scratchpad", subtitle: "Autosaves as you type") {
            TextEditor(text: $text)
                .frame(maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .padding(8).background(.ultraThinMaterial).cornerRadius(12)
                .onChange(of: text) { _, v in UserDefaults.standard.set(v, forKey: "scratchpad") }
        }
    }
}

// MARK: Notes
struct NoteItem: Identifiable, Codable, Equatable { var id = UUID(); var title: String; var body: String }
struct NotesTool: View {
    @State private var notes: [NoteItem] = LocalStorage.load("notes", as: [NoteItem].self) ?? [.init(title: "Welcome", body: "Your first note")]
    @State private var sel: UUID?
    var body: some View {
        ToolContainer("Notes", subtitle: "\(notes.count) notes") {
            HStack(alignment: .top, spacing: 10) {
                List(notes, selection: $sel) { n in Text(n.title).lineLimit(1).tag(n.id) }
                    .listStyle(.plain)
                    .frame(minWidth: 120, maxWidth: 180)
                if let s = sel, let idx = notes.firstIndex(where: { $0.id == s }) {
                    VStack(alignment: .leading) {
                        TextField("Title", text: $notes[idx].title).font(.headline)
                        TextEditor(text: $notes[idx].body).frame(maxHeight: .infinity)
                    }
                } else {
                    Text("Select a note").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                }
                VStack(spacing: 8) {
                    Button("Add") {
                        let n = NoteItem(title: "New note", body: "")
                        notes.append(n); sel = n.id; LocalStorage.save(notes, key: "notes")
                    }
                    Button("Save") { LocalStorage.save(notes, key: "notes") }
                }.controlSize(.small)
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: notes) { _, v in LocalStorage.save(v, key: "notes") }
    }
}

// MARK: Links
struct LinksTool: View {
    @State private var q = ""
    @State private var links: [String] = LocalStorage.load("links", as: [String].self) ?? ["github.com", "apple.com", "x.com"]
    var body: some View {
        ToolContainer("Links", subtitle: "Search the web without a new tab") {
            HStack {
                TextField("Search Google / YouTube / GitHub...", text: $q).textFieldStyle(.roundedBorder)
                    .onSubmit { openSearch() }
                Button("Go") { openSearch() }.controlSize(.small)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], alignment: .leading) {
                    ForEach(links, id: \.self) { l in
                        Button(l) {
                            if let url = URL(string: "https://\(l)") { NSWorkspace.shared.open(url) }
                        }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }
    func openSearch() {
        guard !q.isEmpty else { return }
        let url = "https://www.google.com/search?q=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

// MARK: Emoji
struct EmojiTool: View {
    let emojis = ["😀","😂","🥳","😎","🔥","👍","🙏","🎉","💡","🚀","🍎","☕️","🌧️","🎧","✅","❌","⭐","💻","📝","🎨"]
    var body: some View {
        ToolContainer("Emoji", subtitle: "Click to copy") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], alignment: .leading) {
                ForEach(emojis, id: \.self) { e in
                    Button(e) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(e, forType: .string)
                    }.font(.largeTitle).buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Units
struct UnitsTool: View {
    @State private var input = "100"
    @State private var kind = 0
    let kinds = ["cm→in", "kg→lb", "°C→°F", "km→mi"]
    var result: String {
        let v = Double(input) ?? 0
        switch kind {
        case 0: return String(format: "%.2f in", v / 2.54)
        case 1: return String(format: "%.2f lb", v * 2.20462)
        case 2: return String(format: "%.1f °F", v * 9/5 + 32)
        default: return String(format: "%.2f mi", v * 0.621371)
        }
    }
    var body: some View {
        ToolContainer("Units", subtitle: "Quick conversions, no browser tab") {
            Picker("", selection: $kind) { ForEach(0..<kinds.count, id: \.self) { Text(kinds[$0]).tag($0) } }
                .pickerStyle(.segmented)
            HStack {
                TextField("Value", text: $input).textFieldStyle(.roundedBorder).frame(width: 120)
                Text("= \(result)").font(.title2)
                Spacer()
            }
        }
    }
}

// MARK: Message
struct MessageTool: View {
    @EnvironmentObject var settings: SettingsStore
    var body: some View {
        ToolContainer("Message", subtitle: "Dot-matrix text across the collapsed notch") {
            TextField("Message", text: $settings.customMessage).textFieldStyle(.roundedBorder)
            Text("Shows when Settings → Collapsed shows → Message").font(.caption).foregroundStyle(.secondary)
        }
    }
}
