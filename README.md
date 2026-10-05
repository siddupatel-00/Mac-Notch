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

## Next to sell like NotchBuddy ($5.99)
1. Full Xcode + Apple Developer signing + notarize `dist/*.dmg`
2. License check (LemonSqueezy/Gumroad)
3. Polish: MediaRemote now-playing, real ambient audio files, ScreenTime API, Stripe polling
4. Landing page + TryMacApps submit
