struct ToolDef: Identifiable {
    let id: String
    let name: String
    let icon: String
}

enum ToolRegistry {
    static let all: [ToolDef] = [
        .init(id: "home", name: "Home", icon: "house"),
        .init(id: "music", name: "Music", icon: "music.note"),
        .init(id: "revenue", name: "Revenue", icon: "dollarsign.circle"),
        .init(id: "scratchpad", name: "Scratch", icon: "note.text"),
        .init(id: "shelf", name: "Shelf", icon: "archivebox"),
        .init(id: "calendar", name: "Calendar", icon: "calendar"),
        .init(id: "timers", name: "Clock", icon: "clock"),
        .init(id: "stats", name: "Stats", icon: "cpu"),
        .init(id: "screentime", name: "Screen", icon: "clock"),
        .init(id: "weather", name: "Weather", icon: "cloud.sun"),
        .init(id: "clipboard", name: "Clip", icon: "doc.on.clipboard"),
        .init(id: "notes", name: "Notes", icon: "pencil"),
        .init(id: "files", name: "Files", icon: "folder"),
        .init(id: "links", name: "Links", icon: "link"),
        .init(id: "emoji", name: "Emoji", icon: "face.smiling"),
        .init(id: "sounds", name: "Sounds", icon: "speaker.wave.2"),
        .init(id: "message", name: "Message", icon: "text.bubble"),
        .init(id: "claude", name: "Claude", icon: "brain.head.profile"),
        .init(id: "units", name: "Units", icon: "ruler"),
    ]
}
