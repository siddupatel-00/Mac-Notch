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
struct NoteItem: Identifiable, Codable, Equatable, Sendable { var id = UUID(); var title: String; var body: String }
struct NotesTool: View {
    @StateObject private var settings = SettingsStore.shared
    @GestureState private var listDrag: CGFloat = 0
    @State private var handleHover = false
    @State private var notes: [NoteItem] = LocalStorage.load("notes", as: [NoteItem].self) ?? [.init(title: "Welcome", body: "Your first note")]
    @State private var sel: UUID?
    /// Live list width while dragging (committed to settings on release).
    var listLiveWidth: CGFloat {
        min(300, max(120, CGFloat(settings.notesListWidth) + listDrag))
    }
    var body: some View {
        ToolContainer("Notes", subtitle: "\(notes.count) notes") {
            HStack(alignment: .top, spacing: 0) {
                List(notes, selection: $sel) { n in Text(n.title).lineLimit(1).tag(n.id) }
                    .listStyle(.plain)
                    .frame(width: listLiveWidth)
                    // Drag must track the mouse 1:1 — never ease it.
                    .animation(nil, value: listDrag)
                // Draggable divider: grab to resize the list (persists on release)
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 11)
                    .contentShape(Rectangle())
                    .overlay(
                        HStack(spacing: 0) {
                            Divider()
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white.opacity(handleHover ? 0.4 : 0.0))
                                .frame(width: 4)
                                .padding(.vertical, 24)
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, 2)
                    )
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .updating($listDrag) { v, state, _ in state = v.translation.width }
                            .onEnded { v in
                                settings.notesListWidth = Double(min(300, max(120, CGFloat(settings.notesListWidth) + v.translation.width)))
                            }
                    )
                    .onHover { h in handleHover = h }
                    // Native cursor rect (not push/pop, which AppKit resets on
                    // mouse-move): guarantees ↔ whenever the mouse is over us.
                    .background(ResizeCursorView())
                Group {
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
                }
                .padding(.leading, 10)
                VStack(spacing: 8) {
                    Button("Add") {
                        let n = NoteItem(title: "New note", body: "")
                        notes.append(n); sel = n.id; LocalStorage.save(notes, key: "notes")
                    }
                    Button("Save") { exportSelected() }
                        .disabled(sel == nil)
                    Button { deleteSelected() } label: { Image(systemName: "trash") }
                        .disabled(sel == nil)
                        .help("Delete selected note")
                }.controlSize(.small).padding(.leading, 10)
            }
            .frame(maxHeight: .infinity)
        }
        .onChange(of: notes) { _, v in LocalStorage.save(v, key: "notes") }
    }
    private func deleteSelected() {
        guard let s = sel, let idx = notes.firstIndex(where: { $0.id == s }) else { return }
        notes.remove(at: idx)
        if notes.isEmpty {
            sel = nil
        } else {
            sel = notes[min(idx, notes.count - 1)].id
        }
        LocalStorage.save(notes, key: "notes")
    }
    private func exportSelected() {
        guard let s = sel, let note = notes.first(where: { $0.id == s }) else { return }
        let trimmed = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Untitled" : trimmed
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = safe.hasSuffix(".txt") ? safe : safe + ".txt"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            var dest = url
            if dest.pathExtension.lowercased() != "txt" {
                dest = dest.appendingPathExtension("txt")
            }
            let text = "\(note.title)\n\n\(note.body)"
            try? text.write(to: dest, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: Links
struct LinkItem: Identifiable, Codable, Equatable { var id = UUID(); var url: String; var folderID: UUID? }
struct LinkFolder: Identifiable, Codable, Equatable { var id = UUID(); var name: String; var isCollapsed = false }
struct LinksTool: View {
    @State private var q = ""
    @State private var links: [LinkItem] = LinksTool.migratedLinks()
    @State private var folders: [LinkFolder] = LocalStorage.load("linkFolders", as: [LinkFolder].self) ?? []
    @State private var newURL = ""
    @State private var newFolderName = ""
    @State private var selectedFolderID: UUID?
    @State private var renamingID: UUID?
    @State private var renameText = ""
    @State private var editingLinkID: UUID?
    @State private var editLinkText = ""
    @State private var copiedLinkID: UUID?
    static func normalizeURL(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let lower = t.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return t }
        return "https://\(t)"
    }
    static func migratedLinks() -> [LinkItem] {
        if let items = LocalStorage.load("links", as: [LinkItem].self) { return items }
        if let legacy = LocalStorage.load("links", as: [String].self) {
            return legacy.compactMap { s in guard let n = normalizeURL(s) else { return nil }; return LinkItem(url: n, folderID: nil) }
        }
        return ["github.com", "apple.com", "x.com"].map { LinkItem(url: "https://\($0)", folderID: nil) }
    }
    var body: some View {
        ToolContainer("Links", subtitle: "Search the web without a new tab") {
            HStack {
                TextField("Search Google / YouTube / GitHub...", text: $q).textFieldStyle(.roundedBorder)
                    .onSubmit { openSearch() }
                Button("Go") { openSearch() }.controlSize(.small)
            }
            HStack {
                TextField("Add link — paste URL...", text: $newURL).textFieldStyle(.roundedBorder)
                    .onSubmit { addLink() }
                Picker("Folder", selection: $selectedFolderID) {
                    Text("Unfiled").tag(nil as UUID?)
                    ForEach(folders) { f in Text(f.name).tag(Optional(f.id)) }
                }.pickerStyle(.menu).frame(maxWidth: 120).controlSize(.small)
                Button("Add") { addLink() }.controlSize(.small)
            }
            HStack {
                TextField("New folder...", text: $newFolderName).textFieldStyle(.roundedBorder)
                    .onSubmit { createFolder() }
                Button("Create") { createFolder() }.controlSize(.small)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    folderHeaderRow(title: "Unfiled", count: linksIn(nil).count, collapsible: false, collapsed: false, onToggle: {})
                    ForEach(linksIn(nil)) { linkRow($0) }
                    ForEach(folders) { folderSection($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
            }
            .frame(maxHeight: .infinity)
        }
    }
    @ViewBuilder func folderSection(_ folder: LinkFolder) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if renamingID == folder.id {
                HStack {
                    TextField("Folder name", text: $renameText).textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename() }
                    Button("Save") { commitRename() }.controlSize(.small)
                    Button("Cancel") { renamingID = nil }.controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        toggleFolder(folder)
                    } label: {
                        Image(systemName: folder.isCollapsed ? "chevron.right" : "chevron.down").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Text(folder.name).font(.headline).lineLimit(1)
                    Text("(\(linksIn(folder.id).count))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        renamingID = folder.id; renameText = folder.name
                    } label: {
                        Image(systemName: "pencil").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Button {
                        deleteFolder(folder)
                    } label: {
                        Image(systemName: "trash").font(.caption)
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleFolder(folder) }
            }
            if !folder.isCollapsed {
                ForEach(linksIn(folder.id)) { linkRow($0) }
            }
        }
        .padding(6).background(.ultraThinMaterial).cornerRadius(8)
    }
    @ViewBuilder func linkRow(_ link: LinkItem) -> some View {
        if editingLinkID == link.id {
            HStack(spacing: 6) {
                TextField("https://…", text: $editLinkText).textFieldStyle(.roundedBorder)
                    .onSubmit { commitLinkEdit() }
                Button {
                    commitLinkEdit()
                } label: {
                    Image(systemName: "checkmark").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button {
                    editingLinkID = nil
                } label: {
                    Image(systemName: "xmark").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                Button {
                    openLink(link.url)
                } label: {
                    Text(link.url).lineLimit(1).truncationMode(.middle)
                }.buttonStyle(.bordered)
                Spacer(minLength: 0)
                Menu {
                    Button("Unfiled") { moveLink(link, to: nil) }
                    ForEach(folders) { f in Button(f.name) { moveLink(link, to: f.id) } }
                } label: {
                    Image(systemName: "folder").font(.caption)
                }.menuStyle(.borderlessButton).foregroundStyle(.secondary)
                Button {
                    editingLinkID = link.id; editLinkText = link.url
                } label: {
                    Image(systemName: "pencil").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Edit link")
                Button {
                    deleteLink(link)
                } label: {
                    Image(systemName: "trash").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Delete link")
                Button {
                    copyLink(link)
                } label: {
                    Image(systemName: copiedLinkID == link.id ? "checkmark" : "doc.on.doc").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Copy link")
            }
        }
    }
    @ViewBuilder func folderHeaderRow(title: String, count: Int, collapsible: Bool, collapsed: Bool, onToggle: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            if collapsible {
                Button(action: onToggle) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Text(title).font(.headline).lineLimit(1)
            Text("(\(count))").font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
    func linksIn(_ folderID: UUID?) -> [LinkItem] {
        links.filter { $0.folderID == folderID }
    }
    func persist() {
        LocalStorage.save(links, key: "links")
        LocalStorage.save(folders, key: "linkFolders")
    }
    func addLink() {
        guard let n = Self.normalizeURL(newURL) else { return }
        guard !links.contains(where: { $0.url.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        links.append(LinkItem(url: n, folderID: selectedFolderID))
        newURL = ""
        persist()
    }
    func createFolder() {
        let t = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !folders.contains(where: { $0.name.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        folders.append(LinkFolder(name: t))
        newFolderName = ""
        persist()
    }
    func deleteLink(_ link: LinkItem) {
        links.removeAll { $0.id == link.id }
        persist()
    }
    func commitLinkEdit() {
        guard let id = editingLinkID,
              let i = links.firstIndex(where: { $0.id == id }) else { editingLinkID = nil; return }
        guard let n = Self.normalizeURL(editLinkText) else { return }
        guard !links.contains(where: { $0.id != id && $0.url.caseInsensitiveCompare(n) == .orderedSame }) else { return }
        links[i].url = n
        editingLinkID = nil
        persist()
    }
    func copyLink(_ link: LinkItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link.url, forType: .string)
        copiedLinkID = link.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if copiedLinkID == link.id { copiedLinkID = nil }
        }
    }
    func moveLink(_ link: LinkItem, to folderID: UUID?) {
        guard let i = links.firstIndex(where: { $0.id == link.id }) else { return }
        links[i].folderID = folderID
        persist()
    }
    func deleteFolder(_ folder: LinkFolder) {
        for i in links.indices where links[i].folderID == folder.id { links[i].folderID = nil }
        folders.removeAll { $0.id == folder.id }
        if selectedFolderID == folder.id { selectedFolderID = nil }
        if renamingID == folder.id { renamingID = nil }
        persist()
    }
    func toggleFolder(_ folder: LinkFolder) {
        guard let i = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[i].isCollapsed.toggle()
        persist()
    }
    func commitRename() {
        guard let id = renamingID else { return }
        let t = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { renamingID = nil; return }
        guard !folders.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(t) == .orderedSame }) else { renamingID = nil; return }
        guard let i = folders.firstIndex(where: { $0.id == id }) else { renamingID = nil; return }
        folders[i].name = t
        renamingID = nil
        persist()
    }
    func openLink(_ s: String) {
        let fixed = Self.normalizeURL(s) ?? s
        if let url = URL(string: fixed) { NSWorkspace.shared.open(url) }
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
