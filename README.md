# NotchApp — NotchBuddy clone

Native macOS notch utility (SwiftUI + AppKit, macOS 14+).
Built with Swift Package Manager, no Xcode project required.

## Run it
```
./Scripts/make-app.sh
open dist/NotchApp.app
```
- Hover the top-center notch (or click it) to expand
- Bottom icon bar = 19 tools, toggle in Settings (Cmd+, via Settings scene)
- Works with notch or simulated notch

## 19 tools included
Home, Revenue, Analytics, Scratchpad, Shelf, Calendar, Timers, Stats, Screen Time, Weather, Clipboard, Notes, Files, Links, Emoji, Sounds, Message, Claude, Units

- Revenue/Analytics: enter read-only keys, data stays on Mac
- Weather: Open-Meteo, no key
- Shelf/Files: all local drag-drop + NSImage convert
- Claude: scans ~/.claude/projects
- Themes: Minimal / Playful / Neon in Settings

## License
Free and open source (MIT) — no payments, no license checks, no telemetry.
