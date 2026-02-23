# Spacie

Native macOS disk space analyzer built for Apple Silicon. Visualize disk usage, find large files and duplicates, clean up caches — all in a fast, beautiful interface.

![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![License](https://img.shields.io/badge/License-Non--Commercial-green)
![Platform](https://img.shields.io/badge/Platform-Apple%20Silicon-black)

## Features

**Visualization**
- Sunburst (radial treemap) and rectangular treemap with seamless switching
- Live visualization during scan — diagram builds in real time
- Drill-down navigation with animated transitions and breadcrumb bar
- Color-coded by file type (video, audio, images, code, archives, etc.)

**Scan Engine**
- High-performance POSIX scanner (`fts_open`/`fts_read`) — targets 1M files in under 10 seconds
- Arena-based file tree with string interning — under 500MB RAM for 5M files
- Persistent binary cache with FSEvents incremental invalidation
- APFS-aware: logical/physical size toggle, clone detection, hard link dedup

**Cleanup Tools**
- **Large Files** — Top-N or threshold mode with sortable table
- **Duplicate Finder** — progressive detection (size → partial hash → full SHA-256)
- **Smart Categories** — 13 built-in plugins: Xcode DerivedData, brew, npm, Docker, Gradle, iOS backups, system logs, and more
- **Old Files** — filter by last access date (6 months, 1 year, 2 years)
- **Storage Overview** — system breakdown with purgeable space and recommendations

**Safety**
- Drop Zone with two-step deletion (stage → confirm → Trash)
- SIP-protected paths blocked, dotfiles show warnings
- User-extensible blocklist (`~/.spacie/blocklist.txt`)
- Graceful degradation without Full Disk Access

**Integration**
- Reveal in Finder, Open in Terminal, Copy Path
- Quick Look preview (Space key)
- All volumes: internal, external, network
- Native macOS tabs, keyboard shortcuts, Settings window
- EN + RU localization ready

## Requirements

- macOS 15.0 (Sequoia) or later
- Apple Silicon (arm64)

## Build

```bash
# Clone
git clone https://github.com/AlexGladkov/Spacie.git
cd Spacie

# Option 1: Xcode
open Spacie.xcodeproj
# Build & Run (Cmd+R)

# Option 2: xcodegen (if you modify project.yml)
brew install xcodegen
xcodegen generate
open Spacie.xcodeproj
```

## Project Structure

```
Spacie/
├── App/                        # Entry point, main window, settings
├── Core/
│   ├── Scanner/                # POSIX fts disk scanner
│   ├── FileTree/               # Arena-based tree + string pool
│   ├── Cache/                  # Binary cache + FSEvents monitor
│   ├── Duplicates/             # Progressive hash engine
│   └── SystemInfo/             # Volume, permission, trash managers
├── Features/
│   ├── Visualization/          # Sunburst + treemap (Canvas)
│   ├── DropZone/               # Deletion staging area
│   ├── FileList/               # Large files + old files
│   ├── Duplicates/             # Duplicate finder UI
│   ├── SmartCategories/        # Cleanup categories UI
│   ├── StorageOverview/        # System storage breakdown
│   └── Scan/                   # Volume picker
├── Plugins/
│   ├── Protocol/               # CleanupCategory protocol
│   └── BuiltIn/               # 13 built-in cleanup plugins
└── Shared/                     # Models, extensions, theme
```

## Smart Categories (Built-in Plugins)

| Category | Typical Size | Path |
|----------|-------------|------|
| Xcode DerivedData | 10–100 GB | `~/Library/Developer/Xcode/DerivedData/` |
| Xcode Archives | 5–50 GB | `~/Library/Developer/Xcode/Archives/` |
| Xcode Device Support | 5–30 GB | `~/Library/Developer/Xcode/iOS DeviceSupport/` |
| Homebrew Cache | 1–20 GB | `~/Library/Caches/Homebrew/` |
| npm Cache | 1–10 GB | `~/.npm/_cacache/` |
| node_modules | 5–50 GB | `**/node_modules/` |
| Docker Images | 10–100 GB | `~/Library/Containers/com.docker.docker/` |
| Gradle Cache | 5–30 GB | `~/.gradle/caches/` |
| System Logs | 0.5–5 GB | `/var/log/`, `~/Library/Logs/` |
| Crash Reports | 0.1–2 GB | `~/Library/Logs/DiagnosticReports/` |
| iOS Backups | 10–200 GB | `~/Library/Application Support/MobileSync/Backup/` |
| Old Downloads | varies | `~/Downloads/` (> 30 days) |
| Trash | varies | `~/.Trash/` |

Adding custom plugins: implement the `CleanupCategory` Swift protocol and register in `PluginRegistry`.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+R | Rescan |
| Cmd+1 / Cmd+2 | Sunburst / Treemap |
| Cmd+[ / Cmd+] | Back / Forward |
| Cmd+Up | Parent directory |
| Cmd+Delete | Add to Drop Zone |
| Cmd+Shift+Delete | Empty Drop Zone |
| Space | Quick Look |
| Cmd+I | Get Info |
| Cmd+Shift+G | Go to Folder |
| Cmd+F | Search |
| Cmd+T | New Tab |

## License

**Non-Commercial License.** Free for personal, educational, and research use. Commercial use is prohibited without a separate license agreement. See [LICENSE](LICENSE) for details.
